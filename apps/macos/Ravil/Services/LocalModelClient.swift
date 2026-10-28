import Foundation
import Observation

enum LocalModelProvider: String, CaseIterable, Identifiable {
    case ollama = "Ollama", lmStudio = "LM Studio", compatible = "호환 서버"
    var id: String { rawValue }
    var defaultEndpoint: String {
        self == .ollama ? "http://127.0.0.1:11434/v1" : "http://127.0.0.1:1234/v1"
    }
}

enum LocalModelError: LocalizedError {
    case invalidEndpoint, status(Int), invalidResponse, emptyModels, emptyAnswer
    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "이 Mac의 localhost, 127.0.0.1 또는 ::1 서버 주소를 입력해 주세요."
        case .status(401), .status(403): return "모델 서버의 인증 키를 확인해 주세요."
        case .status(let status): return "로컬 서버가 HTTP \(status)을 반환했습니다."
        case .invalidResponse: return "모델 서버의 응답 형식을 확인해 주세요."
        case .emptyModels: return "모델이 없습니다. 서버에서 사용할 모델을 준비해 주세요."
        case .emptyAnswer: return "모델이 답변을 반환하지 않았습니다."
        }
    }
}

private final class LocalModelSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // A localhost connection must never forward notes or keys to a redirect destination.
        completionHandler(nil)
    }
}

@MainActor @Observable
final class LocalModelClient {
    var provider: LocalModelProvider
    var endpoint: String
    var apiKey = "" // In memory only. Never persisted or logged.
    var selectedModel: String?
    private(set) var availableModels: [String] = []
    private(set) var connected = false
    private(set) var connecting = false
    private(set) var sending = false
    private(set) var status = "연결 전"
    private(set) var errorMessage: String?
    private(set) var messages: [CodexChatMessage] = []
    private(set) var lastResponse: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var connectedEndpoint: URL?
    @ObservationIgnored private var connectedKey = ""
    var ready: Bool { connected && !connecting && !sending && selectedModel != nil }

    init(defaults: UserDefaults = .standard, session: URLSession? = nil) {
        self.defaults = defaults
        let initialProvider = LocalModelProvider(rawValue: defaults.string(forKey: "RavilLocalModelProvider") ?? "") ?? .ollama
        provider = initialProvider
        endpoint = defaults.string(forKey: "RavilLocalModelEndpoint") ?? initialProvider.defaultEndpoint
        selectedModel = defaults.string(forKey: "RavilLocalModelSelection")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.connectionProxyDictionary = [:]
        self.session = session ?? URLSession(configuration: configuration,
                                             delegate: LocalModelSessionDelegate(), delegateQueue: nil)
    }

    static func baseURL(_ raw: String) throws -> URL {
        guard var value = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(value.scheme?.lowercased() ?? ""),
              ["localhost", "127.0.0.1", "::1", "[::1]"].contains(value.host?.lowercased() ?? ""),
              value.user == nil, value.password == nil, value.query == nil, value.fragment == nil,
              value.port == nil || (1...65535).contains(value.port!) else { throw LocalModelError.invalidEndpoint }
        value.path = value.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        value.path = value.path.isEmpty ? "/v1" : "/" + value.path
        guard value.path == "/v1", let result = value.url else { throw LocalModelError.invalidEndpoint }
        return result
    }

    func chooseProvider(_ value: LocalModelProvider) {
        disconnect()
        provider = value
        endpoint = value.defaultEndpoint
        apiKey = ""
        selectedModel = nil
    }

    func connect() {
        disconnect()
        errorMessage = nil
        let token = generation
        let address: URL
        do { address = try Self.baseURL(endpoint) }
        catch { fail(error); return }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        connecting = true
        status = "모델 목록 확인 중…"
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let value = try await request(address.appendingPathComponent("models"), key: key)
                guard generation == token, !Task.isCancelled else { return }
                let rows = value["data"] as? [[String: Any]] ?? []
                let models = Array(Set(rows.compactMap { $0["id"] as? String })).sorted()
                guard !models.isEmpty else { throw LocalModelError.emptyModels }
                availableModels = models
                if selectedModel.map({ !models.contains($0) }) ?? true { selectedModel = models.first }
                connectedEndpoint = address; connectedKey = key
                connected = true; connecting = false
                endpoint = address.absoluteString
                defaults.set(endpoint, forKey: "RavilLocalModelEndpoint")
                defaults.set(provider.rawValue, forKey: "RavilLocalModelProvider")
                status = "\(provider.rawValue) 연결됨"
            } catch {
                guard generation == token else { return }
                fail(error)
            }
        }
    }

    @discardableResult func send(_ input: String) -> Bool {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ready, !text.isEmpty, text.count <= 16000, let model = selectedModel,
              availableModels.contains(model), let address = connectedEndpoint else { return false }
        guard (try? Self.baseURL(endpoint)) == address, apiKey.trimmingCharacters(in: .whitespacesAndNewlines) == connectedKey else {
            errorMessage = "연결 설정이 바뀌었습니다. 다시 연결해 주세요."
            return false
        }
        messages.append(CodexChatMessage(role: "user", text: text))
        let history = messages.suffix(12).filter { !$0.text.isEmpty }.map { ["role": $0.role, "content": $0.text] }
        messages.append(CodexChatMessage(role: "assistant", text: ""))
        sending = true; errorMessage = nil; lastResponse = nil
        status = "\(model) 응답 중…"
        defaults.set(model, forKey: "RavilLocalModelSelection")
        let token = generation
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let value = try await request(address.appendingPathComponent("chat/completions"), key: connectedKey,
                    body: ["model": model, "messages": history, "stream": false, "max_tokens": 1024])
                guard generation == token, !Task.isCancelled else { return }
                let choice = (value["choices"] as? [[String: Any]])?.first
                let message = choice?["message"] as? [String: Any]
                let answer = (message?["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !answer.isEmpty else { throw LocalModelError.emptyAnswer }
                if messages.last?.role == "assistant" { messages[messages.count - 1].text = answer }
                lastResponse = answer; sending = false
                status = "\(provider.rawValue) 연결됨"
            } catch {
                guard generation == token else { return }
                fail(error)
            }
        }
        return true
    }

    func cancel() {
        task?.cancel(); task = nil
        generation = UUID()
        sending = false; connecting = false; lastResponse = nil
        if messages.last?.role == "assistant", messages.last?.text.isEmpty == true {
            messages[messages.count - 1].text = "응답을 중단했습니다."
        }
        status = connected ? "\(provider.rawValue) 연결됨" : "연결 전"
    }

    func disconnect() {
        cancel()
        connected = false; connectedEndpoint = nil; connectedKey = ""
        availableModels = []; messages = []; lastResponse = nil
        status = "연결 전"
    }

    private func request(_ url: URL, key: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.timeoutInterval = body == nil ? 12 : 180
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !key.isEmpty { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw LocalModelError.invalidResponse }
        guard (200...299).contains(response.statusCode) else { throw LocalModelError.status(response.statusCode) }
        guard data.count <= 4_000_000,
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LocalModelError.invalidResponse }
        return value
    }

    private func fail(_ error: Error) {
        connecting = false; sending = false; lastResponse = nil
        errorMessage = error is LocalModelError ? error.localizedDescription : "로컬 서버에 연결하지 못했습니다. 서버 실행과 주소를 확인해 주세요."
        status = connected ? "\(provider.rawValue) · 응답 확인 필요" : "연결 확인 필요"
        if messages.last?.role == "assistant", messages.last?.text.isEmpty == true {
            messages[messages.count - 1].text = errorMessage ?? "응답 오류"
        }
    }
}
