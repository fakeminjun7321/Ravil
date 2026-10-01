import AppKit
import CryptoKit
import Foundation
import Network
import Observation
import Security

enum GoogleAccountError: LocalizedError {
    case invalidClient
    case invalidFolder
    case notConnected
    case denied
    case callbackTimeout
    case callbackInvalid
    case authorizationExpired
    case tokenExchange(Int, String? = nil)
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidClient: return "Google Cloud의 Desktop OAuth 클라이언트 ID를 입력해 주세요."
        case .invalidFolder: return "백업할 Drive 폴더 링크를 입력해 주세요."
        case .notConnected: return "Google 계정을 먼저 연결해 주세요."
        case .denied: return "Google 계정 연결이 취소되거나 거부되었습니다."
        case .callbackTimeout: return "Google 로그인 응답을 기다리는 시간이 초과됐습니다."
        case .callbackInvalid: return "Google 로그인 응답을 확인할 수 없습니다."
        case .authorizationExpired: return "Google 연결이 만료됐습니다. 다시 연결해 주세요."
        case .tokenExchange(let code, let reason): return "Google 인증에 실패했습니다 (HTTP \(code))." + (reason.map { " " + $0 } ?? "")
        case .keychain(let status): return "macOS 키체인 접근에 실패했습니다 (\(status))."
        }
    }
}

private enum GoogleRefreshTokenStore {
    private static let service = "com.minjun.ravil.google-drive-refresh"

    static func read(clientID: String) throws -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: clientID,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw GoogleAccountError.keychain(status)
        }
        return value
    }

    static func save(_ token: String, clientID: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: clientID]
        let data = Data(token.utf8)
        let status = SecItemUpdate(query as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw GoogleAccountError.keychain(status) }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw GoogleAccountError.keychain(addStatus) }
    }

    static func delete(clientID: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: clientID]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GoogleAccountError.keychain(status)
        }
    }
}

private struct GoogleTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

@MainActor
final class GoogleOAuthLoopback {
    private var listener: NWListener?
    private var ready: CheckedContinuation<Int, Error>?
    private var callback: CheckedContinuation<String, Error>?
    private var callbackResult: Result<String, Error>?
    private var completed = false
    private let expectedState: String
    private let queue = DispatchQueue(label: "com.minjun.ravil.google-oauth-loopback")

    init(expectedState: String) { self.expectedState = expectedState }

    func start() async throws -> Int {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host("127.0.0.1"), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in self?.stateChanged(state) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in self?.accept(connection) }
        }
        return try await withCheckedThrowingContinuation { continuation in
            ready = continuation
            listener.start(queue: queue)
        }
    }

    func waitForCode() async throws -> String {
        if let callbackResult { return try callbackResult.get() }
        return try await withCheckedThrowingContinuation { continuation in
            callback = continuation
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(180))
                self?.finish(.failure(GoogleAccountError.callbackTimeout))
            }
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func stateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let port = listener?.port?.rawValue else {
                ready?.resume(throwing: GoogleAccountError.callbackInvalid)
                ready = nil
                return
            }
            ready?.resume(returning: Int(port))
            ready = nil
        case .failed:
            ready?.resume(throwing: GoogleAccountError.callbackInvalid)
            ready = nil
            finish(.failure(GoogleAccountError.callbackInvalid))
        default: break
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        readRequest(connection, buffer: Data())
    }

    private func readRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, _ in
            Task { @MainActor [weak self] in
                guard let self else { connection.cancel(); return }
                var received = buffer
                if let data { received.append(data) }
                guard received.count <= 16_384 else {
                    self.respond(connection, status: "400 Bad Request", message: "로그인 응답이 너무 깁니다.")
                    return
                }
                if received.range(of: Data("\r\n".utf8)) != nil {
                    self.process(received, connection: connection)
                } else if complete {
                    self.respond(connection, status: "400 Bad Request", message: "잘못된 로그인 응답입니다.")
                } else {
                    self.readRequest(connection, buffer: received)
                }
            }
        }
    }

    private func process(_ data: Data, connection: NWConnection) {
        guard let request = String(data: data, encoding: .utf8),
              let first = request.components(separatedBy: "\r\n").first,
              first.hasPrefix("GET "),
              let path = first.split(separator: " ").dropFirst().first,
              let url = URLComponents(string: "http://127.0.0.1\(path)"),
              url.path == "/oauth2callback",
              url.queryItems?.first(where: { $0.name == "state" })?.value == expectedState else {
            respond(connection, status: "400 Bad Request", message: "잘못된 로그인 응답입니다.")
            return
        }
        if url.queryItems?.contains(where: { $0.name == "error" }) == true {
            respond(connection, status: "200 OK", message: "Ravil 계정 연결이 취소되었습니다.")
            finish(.failure(GoogleAccountError.denied))
            return
        }
        guard let code = url.queryItems?.first(where: { $0.name == "code" })?.value,
              !code.isEmpty, !completed else {
            respond(connection, status: "400 Bad Request", message: "로그인 코드를 확인할 수 없습니다.")
            return
        }
        respond(connection, status: "200 OK", message: "Ravil로 돌아가 연결 결과를 확인해 주세요.")
        finish(.success(code))
    }

    private func respond(_ connection: NWConnection, status: String, message: String) {
        let html = "<html><meta charset=\"utf-8\"><body><p>\(message)</p></body></html>"
        let body = Data(html.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func finish(_ result: Result<String, Error>) {
        guard !completed else { return }
        completed = true
        callbackResult = result
        switch result {
        case .success(let code):
            callback?.resume(returning: code)
        case .failure(let error):
            callback?.resume(throwing: error)
        }
        callback = nil
        stop()
    }
}

@MainActor @Observable
final class GoogleDriveAccount {
    var clientID: String = GoogleDriveConfiguration.resolvedClientID(
        override: UserDefaults.standard.string(forKey: "RavilGoogleClientID"),
        bundled: GoogleDriveConfiguration.bundledClientID)
    var rootFolderID: String = UserDefaults.standard.string(forKey: "RavilGoodnotesRootFolderID") ?? ""
    var configurationReady: Bool { GoogleDriveConfiguration.validClientID(clientID) }
    var automaticEnabled = (UserDefaults.standard.object(forKey: "RavilGoodnotesAutoSyncEnabled") as? Bool) ?? true
    var status = "Google 계정 미연결"
    var isConnected = false
    var isConnecting = false
    var isSyncing = false
    var requiresReconnect = false
    var lastSyncSummary = ""
    var onImported: (() -> Void)?

    @ObservationIgnored private var accessToken: String?
    @ObservationIgnored private var accessTokenExpiresAt = Date.distantPast
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var activeSync: Task<GoodnotesSyncReport, Error>?
    @ObservationIgnored private var connectionEpoch = 0

    private var savedRootFolderID: String {
        GoogleDriveConfiguration.folderID(from:
            UserDefaults.standard.string(forKey: "RavilGoodnotesRootFolderID") ?? "") ?? ""
    }

    init() {
        guard !AppPaths.isVerificationProfile else { status = "검증용 보관함 · 계정 연결 안 함"; return }
        isConnected = (try? GoogleRefreshTokenStore.read(clientID: clientID)) != nil
        if isConnected { status = "Google 연결 저장됨" }
    }

    func saveConfiguration() {
        let wasPolling = pollTask != nil
        if wasPolling { stopPolling() }
        clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        rootFolderID = GoogleDriveConfiguration.folderID(from: rootFolderID)
            ?? rootFolderID.trimmingCharacters(in: .whitespacesAndNewlines)
        if clientID == GoogleDriveConfiguration.bundledClientID {
            UserDefaults.standard.removeObject(forKey: "RavilGoogleClientID")
        } else {
            UserDefaults.standard.set(clientID, forKey: "RavilGoogleClientID")
        }
        UserDefaults.standard.set(rootFolderID, forKey: "RavilGoodnotesRootFolderID")
        isConnected = (try? GoogleRefreshTokenStore.read(clientID: clientID)) != nil
        if !isConnected { stopPolling(); status = "Google 계정 미연결"; requiresReconnect = false }
        else if wasPolling && automaticEnabled { startPolling() }
    }

    func connect() async {
        guard !isConnecting else { return }
        isConnecting = true
        defer { isConnecting = false }
        saveConfiguration()
        guard configurationReady else {
            status = GoogleAccountError.invalidClient.localizedDescription
            return
        }
        guard GoogleDriveConfiguration.folderID(from: rootFolderID) != nil else {
            status = GoogleAccountError.invalidFolder.localizedDescription
            return
        }
        do {
            let state = try Self.randomString()
            let verifier = try Self.randomString()
            let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
            let loopback = GoogleOAuthLoopback(expectedState: state)
            let port = try await loopback.start()
            defer { loopback.stop() }
            let redirect = "http://127.0.0.1:\(port)/oauth2callback"
            var url = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
            url.queryItems = [
                URLQueryItem(name: "client_id", value: clientID),
                URLQueryItem(name: "redirect_uri", value: redirect),
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "scope", value: "https://www.googleapis.com/auth/drive.readonly"),
                URLQueryItem(name: "access_type", value: "offline"),
                URLQueryItem(name: "prompt", value: "select_account consent"),
                URLQueryItem(name: "state", value: state),
                URLQueryItem(name: "code_challenge", value: challenge),
                URLQueryItem(name: "code_challenge_method", value: "S256")
            ]
            guard let authURL = url.url, NSWorkspace.shared.open(authURL) else {
                throw GoogleAccountError.callbackInvalid
            }
            status = "브라우저에서 Google 연결을 마쳐 주세요"
            let code = try await loopback.waitForCode()
            let token = try await Self.tokenRequest([
                "client_id": clientID, "code": code, "code_verifier": verifier,
                "grant_type": "authorization_code", "redirect_uri": redirect
            ])
            guard let refresh = token.refreshToken else { throw GoogleAccountError.callbackInvalid }
            try GoogleRefreshTokenStore.save(refresh, clientID: clientID)
            accessToken = token.accessToken
            accessTokenExpiresAt = Date().addingTimeInterval(TimeInterval(token.expiresIn ?? 3600) - 60)
            connectionEpoch += 1
            isConnected = true
            requiresReconnect = false
            status = "Google 연결됨 · 선택한 폴더만 탐색"
            if automaticEnabled { startPolling() }
        } catch {
            status = error.localizedDescription
        }
    }

    func disconnect() {
        connectionEpoch += 1
        stopPolling()
        do { try GoogleRefreshTokenStore.delete(clientID: clientID) }
        catch { status = error.localizedDescription; return }
        accessToken = nil
        accessTokenExpiresAt = .distantPast
        isConnected = false
        requiresReconnect = false
        status = "이 Mac의 Google 연결 정보를 지웠습니다"
    }

    func setAutomaticEnabled(_ enabled: Bool) {
        automaticEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "RavilGoodnotesAutoSyncEnabled")
        if enabled { startPolling() } else { stopPolling() }
    }

    func startPolling() {
        guard automaticEnabled, isConnected, !requiresReconnect, pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.syncNow()
                try? await Task.sleep(for: .seconds(15 * 60))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        activeSync?.cancel()
    }

    func syncNow() async {
        guard !isSyncing else { return }
        guard !requiresReconnect else {
            status = GoogleAccountError.authorizationExpired.localizedDescription
            return
        }
        let root = savedRootFolderID
        guard root.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
            status = GoogleAccountError.invalidFolder.localizedDescription
            return
        }
        isSyncing = true
        let epoch = connectionEpoch
        status = "PDF 변경 확인 중…"
        defer { isSyncing = false }
        do {
            let token = try await validAccessToken()
            guard isConnected && epoch == connectionEpoch else { throw CancellationError() }
            let worker = Task.detached(priority: .utility) {
                let database = try LibraryDatabase()
                return try await GoodnotesAutoSync(source: GoogleDrivePDFSource(accessToken: token),
                                                   database: database, rootFolderID: root).run()
            }
            activeSync = worker
            let report = try await worker.value
            activeSync = nil
            guard isConnected && epoch == connectionEpoch else { throw CancellationError() }
            let newVersions = report.imported?.newVersions ?? 0
            lastSyncSummary = "PDF \(report.discoveredPDFs)개 확인 · 변경 \(report.downloadedPDFs)개 · 새 판본 \(newVersions)개"
            status = "마지막 확인: \(Date().formatted(date: .abbreviated, time: .shortened))"
            if report.reclassifiedMaterials > 0 {
                lastSyncSummary += " · 분류 \(report.reclassifiedMaterials)개 갱신"
            }
            if report.libraryChanged { onImported?() }
        } catch {
            activeSync = nil
            if epoch != connectionEpoch { return }
            status = error.localizedDescription
            if case GoogleAccountError.authorizationExpired = error {
                accessToken = nil
                accessTokenExpiresAt = .distantPast
                requiresReconnect = true
                stopPolling()
            }
            if case GoodnotesSyncError.http(let code) = error, code == 429 || code == 403 {
                stopPolling()
            }
            if case GoogleAccountError.tokenExchange(let code, _) = error, code == 400 || code == 401 {
                stopPolling()
            }
        }
    }

    private func validAccessToken() async throws -> String {
        guard isConnected, let refresh = try GoogleRefreshTokenStore.read(clientID: clientID) else {
            throw GoogleAccountError.notConnected
        }
        if let accessToken, Date() < accessTokenExpiresAt { return accessToken }
        let token = try await Self.tokenRequest([
            "client_id": clientID, "refresh_token": refresh, "grant_type": "refresh_token"
        ])
        accessToken = token.accessToken
        accessTokenExpiresAt = Date().addingTimeInterval(TimeInterval(token.expiresIn ?? 3600) - 60)
        return token.accessToken
    }

    private static func tokenRequest(_ fields: [String: String]) async throws -> GoogleTokenResponse {
        let parameters = GoogleDriveConfiguration.tokenFields(fields,
            bundledID: GoogleDriveConfiguration.bundledClientID,
            bundledSecret: GoogleDriveConfiguration.bundledClientSecret)
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = GoogleDriveConfiguration.tokenBody(parameters)
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GoogleAccountError.callbackInvalid }
        guard http.statusCode == 200 else {
            if GoogleDriveConfiguration.isExpiredRefreshResponse(statusCode: http.statusCode,
                    fields: fields, data: data) {
                throw GoogleAccountError.authorizationExpired
            }
            throw GoogleAccountError.tokenExchange(http.statusCode, GoogleDriveConfiguration.safeTokenError(data))
        }
        return try JSONDecoder().decode(GoogleTokenResponse.self, from: data)
    }

    private static func randomString() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw GoogleAccountError.callbackInvalid
        }
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
