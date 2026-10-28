import AppKit
import Foundation
import Observation
import Security
import UniformTypeIdentifiers
import CryptoKit
import UserNotifications

private struct WorkspaceCredentials: Codable { var token: String; var owner: String; var email: String }
private enum WorkspaceKeychain {
    static func query(_ url: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.minjun.ravil.workspace",
         kSecAttrAccount as String: url]
    }
    static func read(_ url: String) -> WorkspaceCredentials? {
        var q = query(url); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(WorkspaceCredentials.self, from: data)
    }
    static func save(_ value: WorkspaceCredentials, url: String) throws {
        let data = try JSONEncoder().encode(value), q = query(url)
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw DatabaseError.sqlite("작업 공간 로그인 정보를 키체인에 저장하지 못했습니다.") }
        var item = q; item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw DatabaseError.sqlite("키체인에 저장하지 못했습니다.") }
    }
    static func delete(_ url: String) { SecItemDelete(query(url) as CFDictionary) }
}
@MainActor @Observable
final class PersonalWorkspace {
    var entities: [WorkspaceEntity] = []
    var owner = "guest"
    var email = ""
    var status = "기기에 저장됨"
    var error: String?
    var selectedRecordID: String?
    var selectedSubjectID = ""
    var selectedProjectID = ""
    var isSyncing = false
    var baseURL: String
    var isConnected: Bool { credentials != nil }
    var hasGuestRecords: Bool { ((try? load(owner: "guest")) ?? []).contains { !$0.deleted } }
    @ObservationIgnored private var credentials: WorkspaceCredentials?
    @ObservationIgnored private var root: URL
    @ObservationIgnored private var useKeychain: Bool
    @ObservationIgnored private let network: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var studyTask: Task<Void, Never>?
    @ObservationIgnored private var studySeconds = 0
    var studyingTaskID: String?

    init(baseURL: String? = nil, root: URL? = nil, useKeychain: Bool = true) {
        self.baseURL = baseURL ?? UserDefaults.standard.string(forKey: "RavilWorkspaceURL")
            ?? Bundle.main.object(forInfoDictionaryKey: "RavilWorkspaceURL") as? String ?? ""
        self.root = root ?? AppPaths.applicationSupport.appendingPathComponent("Workspace", isDirectory: true)
        self.useKeychain = useKeychain && !AppPaths.isVerificationProfile
        if self.useKeychain, let value = WorkspaceKeychain.read(self.baseURL) {
            credentials = value; owner = value.owner; email = value.email
        }
        do { entities = try load(owner: owner) } catch { self.error = error.localizedDescription }
        if credentials != nil {
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.sync()
                    try? await Task.sleep(for: .seconds(30))
                }
            }
        }
    }
    private func location(owner: String) -> URL {
        let hash = SHA256.hash(data: Data(owner.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(hash + ".json")
    }
    private func load(owner: String) throws -> [WorkspaceEntity] {
        let url = location(owner: owner)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([WorkspaceEntity].self, from: Data(contentsOf: url))
    }
    func persist() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try JSONEncoder().encode(entities).write(to: location(owner: owner), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: location(owner: owner).path)
    }
    func items(_ kind: String) -> [WorkspaceEntity] { entities.filter { $0.kind == kind && !$0.deleted }.sorted { $0.updatedAt > $1.updatedAt } }
    func get(_ id: String?) -> WorkspaceEntity? { entities.first { $0.id == id && !$0.deleted } }
    var records: [WorkspaceEntity] {
        items("record").filter { (selectedSubjectID.isEmpty || $0.payload.list("subjectIDs").contains(selectedSubjectID)) &&
            (selectedProjectID.isEmpty || $0.payload.list("projectIDs").contains(selectedProjectID)) }
    }
    @discardableResult func put(_ kind: String, _ payload: [String: WorkspaceValue], id: String = UUID().uuidString.lowercased(), deleted: Bool = false, expectedRevision: Int? = nil) throws -> WorkspaceEntity {
        let old = entities.first { $0.id == id }
        let payload = kind == "record" ? WorkspaceAnalysisSupport.invalidating(payload, previous: old?.payload) : payload
        if let old, old.payload == payload, old.deleted == deleted { return old }
        let value = WorkspaceEntity(id: id, kind: kind, payload: payload, revision: expectedRevision ?? old?.revision ?? 0,
            deleted: deleted, updatedAt: ISO8601DateFormatter().string(from: Date()), pending: true, remoteJSON: old?.remoteJSON)
        let previous = entities
        entities.removeAll { $0.id == id }; entities.append(value)
        do { try persist() } catch { entities = previous; throw error }
        status = "기기에 저장됨"; return value
    }
    @discardableResult func saveRecord(id: String?, title: String, body: String, subjectID: String, projectID: String, expectedRevision: Int? = nil) throws -> WorkspaceEntity {
        guard body.count <= 60000 else { throw DatabaseError.sqlite("긴 기록은 60,000자 이내로 나눠 주세요.") }
        let old = get(id); var p = old?.payload ?? [:]
        p["title"] = .string(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? String((body.components(separatedBy: .newlines).first { !$0.isEmpty } ?? "제목 없는 기록").prefix(70)) : title)
        p["body"] = .string(body); p["kind"] = .string(body.hasPrefix("/활동") ? "activity" : p.text("kind").isEmpty ? "note" : p.text("kind"))
        func links(_ key: String, _ choice: String) -> WorkspaceValue {
            let previous = old?.payload.list(key) ?? []
            if previous.first == choice { return .list(previous) }
            return .list(choice.isEmpty ? [] : [choice] + previous.dropFirst().filter { $0 != choice })
        }
        p["subjectIDs"] = links("subjectIDs", subjectID); p["projectIDs"] = links("projectIDs", projectID)
        if p["fileIDs"] == nil { p["fileIDs"] = .list([]) }; if p["tags"] == nil { p["tags"] = .list([]) }
        if p["createdAt"] == nil { p["createdAt"] = .string(ISO8601DateFormatter().string(from: Date())) }
        let result = try put("record", p, id: id ?? UUID().uuidString.lowercased(), expectedRevision: expectedRevision)
        selectedRecordID = result.id
        return result
    }
    func organize(_ record: WorkspaceEntity) throws -> Int {
        let formatter = ISO8601DateFormatter()
        var createdAt = formatter.date(from: record.payload.text("createdAt"))
        if createdAt == nil { formatter.formatOptions.insert(.withFractionalSeconds); createdAt = formatter.date(from: record.payload.text("createdAt")) }
        let parsed = WorkspacePlanParser.parse(record.payload.text("body"), referenceDate: createdAt ?? Date())
        let original = entities; var retained = Set<String>()
        do {
            for (planOrder, task) in parsed.tasks.enumerated() {
                let id = task.id(recordID: record.id); retained.insert(id)
                var p = task.payload; p["planOrder"] = .number(Double(planOrder)); p["recordID"] = .string(record.id); p["subjectIDs"] = record.payload["subjectIDs"]
                p["completed"] = .number(Double(min(get(id)?.payload.int("completed") ?? 0, task.repetitions)))
                if let existing = get(id) { p["minutes"] = existing.payload["minutes"] }
                else {
                    let evidence = items("observation").filter { $0.payload.text("event") == "study" &&
                        $0.payload.text("action") == task.action && $0.payload.int("minutes") > 0 }
                    if evidence.count >= 3 {
                        let times = evidence.map { $0.payload.int("minutes") }.sorted()
                        p["minutes"] = .number(Double(max(5, min(180, Int(((times.count.isMultiple(of: 2) ? Double(times[times.count / 2 - 1] + times[times.count / 2]) / 2 : Double(times[times.count / 2])) / 5).rounded()) * 5))))
                        p["estimatedFromIDs"] = .list(evidence.map(\.id))
                    }
                }
                _ = try put("task", p, id: id)
            }
            for task in items("task") where task.payload.text("recordID") == record.id && !retained.contains(task.id) {
                _ = try put("task", task.payload, id: task.id, deleted: true)
            }
            var p = record.payload; p["kind"] = .string("plan"); p["parseWarnings"] = .list(parsed.warnings)
            _ = try put("record", p, id: record.id)
            try observe("planChanged", recordID: record.id)
            return parsed.tasks.count
        } catch { entities = original; try? persist(); throw error }
    }
    func observe(_ event: String, recordID: String? = nil, taskID: String? = nil, minutes: Int? = nil, action: String? = nil) throws {
        var p: [String: WorkspaceValue] = ["event": .string(event), "at": .string(ISO8601DateFormatter().string(from: Date()))]
        if let recordID { p["recordID"] = .string(recordID) }; if let taskID { p["taskID"] = .string(taskID) }
        if let minutes { p["minutes"] = .number(Double(minutes)) }; if let action { p["action"] = .string(action) }
        _ = try put("observation", p)
    }
    func complete(_ task: WorkspaceEntity) throws {
        var p = task.payload; let count = p.int("completed") >= p.int("repetitions") ? 0 : p.int("completed") + 1
        p["completed"] = .number(Double(count)); _ = try put("task", p, id: task.id)
        try observe("complete", recordID: p.text("recordID"), taskID: task.id, action: p.text("action"))
    }
    func toggleStudy(_ task: WorkspaceEntity) throws {
        if let id = studyingTaskID {
            studyTask?.cancel(); studyTask = nil; studyingTaskID = nil
            if let studied = get(id) { try observe("study", recordID: studied.payload.text("recordID"), taskID: id, minutes: studySeconds / 60, action: studied.payload.text("action")) }
        } else {
            studyingTaskID = task.id; studySeconds = 0
            studyTask = Task { [weak self] in
                while !Task.isCancelled { try? await Task.sleep(for: .seconds(1)); guard !Task.isCancelled else { return }
                    if NSApp.isActive { self?.studySeconds += 1 }
                }
            }
        }
    }
    func request(_ path: String, body: WorkspaceValue? = nil, method: String? = nil) async throws -> (WorkspaceValue, HTTPURLResponse) {
        guard let base = URL(string: baseURL), base.scheme == "https" || (base.scheme == "http" && ["127.0.0.1", "localhost"].contains(base.host ?? "")) else { throw DatabaseError.sqlite("작업 공간 서버 주소를 확인해 주세요.") }
        var request = URLRequest(url: base.appendingPathComponent("api/" + path))
        request.httpMethod = method ?? (body == nil ? "GET" : "POST"); request.timeoutInterval = 45
        if let host = base.host { request.setValue((base.scheme ?? "https") + "://" + host + (base.port.map { ":" + String($0) } ?? ""), forHTTPHeaderField: "Origin") }
        if let credentials { request.setValue("Bearer " + credentials.token, forHTTPHeaderField: "Authorization") }
        if let body { request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = try JSONEncoder().encode(body) }
        let (data, response) = try await network.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw DatabaseError.sqlite("서버 응답을 확인하지 못했습니다.") }
        let value = try JSONDecoder().decode(WorkspaceValue.self, from: data)
        guard (200..<300).contains(response.statusCode) else { throw DatabaseError.sqlite(value.object.text("error").isEmpty ? value.object.text("message") : value.object.text("error")) }
        return (value, response)
    }
    func signIn(email: String, password: String, name: String? = nil) async throws {
        var p: [String: WorkspaceValue] = ["email": .string(email), "password": .string(password)]
        if let name { p["name"] = .string(name) }
        let (value, response) = try await request(name == nil ? "auth/sign-in/email" : "auth/sign-up/email", body: .object(p))
        let object = value.object, user = object["user"]?.object ?? [:]
        let token = response.value(forHTTPHeaderField: "set-auth-token") ?? object.text("token")
        guard !token.isEmpty, !user.text("id").isEmpty else { throw DatabaseError.sqlite("로그인 응답을 확인하지 못했습니다.") }
        let credential = WorkspaceCredentials(token: token, owner: user.text("id"), email: user.text("email"))
        if useKeychain { try WorkspaceKeychain.save(credential, url: baseURL); UserDefaults.standard.set(baseURL, forKey: "RavilWorkspaceURL") }
        credentials = credential; owner = credential.owner; self.email = credential.email
        selectedSubjectID = ""; selectedProjectID = ""; studyingTaskID = nil; studyTask?.cancel()
        entities = try load(owner: owner); selectedRecordID = nil
        await sync()
    }
    func signOut() async throws {
        _ = try? await request("auth/sign-out", body: .object([:]))
        if useKeychain { WorkspaceKeychain.delete(baseURL) }
        credentials = nil; owner = "guest"; email = ""; entities = try load(owner: owner); selectedRecordID = nil
        selectedSubjectID = ""; selectedProjectID = ""; studyingTaskID = nil; studyTask?.cancel(); status = "기기에 저장됨"
    }
    func adoptGuest() async throws {
        guard isConnected else { return }
        for var e in try load(owner: "guest") { e.revision = 0; e.pending = true; e.remoteJSON = nil; entities.removeAll { $0.id == e.id }; entities.append(e) }
        try persist(); try? FileManager.default.removeItem(at: location(owner: "guest")); await sync()
    }
    func sync() async {
        guard credentials != nil, !isSyncing else { return }
        isSyncing = true; status = "동기화 중…"
        let syncOwner = owner
        defer { isSyncing = false }
        do {
            let pending = Array(entities.filter { $0.pending == true && $0.remoteJSON == nil }.prefix(100))
            if !pending.isEmpty {
                let encoded = try JSONEncoder().encode(pending)
                let changes = try JSONDecoder().decode(WorkspaceValue.self, from: encoded)
                let (value, _) = try await request("sync", body: .object(["changes": changes]))
                guard owner == syncOwner, credentials != nil else { return }
                if case .array(let results) = value.object["results"] {
                    for result in results {
                        let p = result.object
                        guard let index = entities.firstIndex(where: { $0.id == p.text("id") }), let raw = p["entity"], raw != .null else { continue }
                        let remote = try JSONDecoder().decode(WorkspaceEntity.self, from: JSONEncoder().encode(raw))
                        if p["applied"] == .bool(true) {
                            if entities[index].payload == pending.first(where: { $0.id == remote.id })?.payload { entities[index] = remote; entities[index].pending = false }
                            else { entities[index].revision = remote.revision }
                        } else { entities[index].remoteJSON = String(decoding: try JSONEncoder().encode(remote), as: UTF8.self) }
                    }
                }
            }
            let (value, _) = try await request("workspace")
            guard owner == syncOwner, credentials != nil else { return }
            if let raw = value.object["entities"] {
                let remotes = try JSONDecoder().decode([WorkspaceEntity].self, from: JSONEncoder().encode(raw))
                for var remote in remotes {
                    if let index = entities.firstIndex(where: { $0.id == remote.id }), entities[index].pending == true {
                        if remote.revision != entities[index].revision && entities[index].remoteJSON == nil {
                            entities[index].remoteJSON = String(decoding: try JSONEncoder().encode(remote), as: UTF8.self)
                        }
                    } else { remote.pending = false; entities.removeAll { $0.id == remote.id }; entities.append(remote) }
                }
            }
            try persist()
            try await notifyBackupIfNeeded()
            status = entities.contains { $0.remoteJSON != nil } ? "동시 수정 확인 필요" : entities.contains { $0.pending == true } ? "추가 변경 동기화 대기" : "클라우드에 저장됨"
            error = nil
        } catch { self.error = error.localizedDescription; status = "기기에 저장됨 · 동기화 대기" }
    }
    func resolveConflict(_ id: String, keepCopy: Bool) async throws {
        guard let local = get(id), let json = local.remoteJSON else { return }
        var remote = try JSONDecoder().decode(WorkspaceEntity.self, from: Data(json.utf8))
        if keepCopy { _ = try put(local.kind, local.payload) }
        remote.pending = false; remote.remoteJSON = nil
        entities.removeAll { $0.id == id }; entities.append(remote); try persist(); await sync()
    }
    func search(_ query: String) -> [WorkspaceEntity] {
        let terms = query.lowercased().split(separator: " ").map(String.init).filter { !["전에", "내가", "했던", "적은", "기록", "메모", "찾아", "찾아줘", "계획"].contains($0) }
        return items("record").filter { e in
            var parts = [e.title, e.payload.text("body")] + e.payload.list("tags")
            parts += (e.payload.list("subjectIDs") + e.payload.list("projectIDs")).compactMap { get($0)?.title }
            parts += e.payload.list("projectHistory") + e.payload.list("examHistory")
            if let analysis = WorkspaceAnalysisSupport.current(e.payload) {
                parts += [analysis.text("summary"), analysis.text("answer")] + analysis.list("tags")
                parts += analysis["connections"]?.elements.map { $0.object.text("reason") } ?? []
                parts += analysis["suggestions"]?.elements.map { $0.object.text("text") } ?? []
            }
            let text = parts.joined(separator: " ").lowercased()
            return terms.isEmpty || terms.contains { text.contains($0) }
        }
    }
    func exportBackup(projectID: String, to url: URL) async throws {
        let (value, _) = try await request("backup/" + projectID, body: .object([:]))
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func verifyBackup(projectID: String, at url: URL) async throws -> String {
        let value = try JSONDecoder().decode(WorkspaceValue.self, from: Data(contentsOf: url))
        let (result, _) = try await request("backup/" + projectID + "/verify", body: value)
        guard result.object["verified"] == .bool(true) else { throw DatabaseError.sqlite("백업을 확인하지 못했습니다.") }
        return result.object.text("snapshotID")
    }
    func finishProject(_ id: String, snapshotID: String) async throws {
        _ = try await request("projects/" + id + "/finish", body: .object(["snapshotID": .string(snapshotID)]))
        await sync(); selectedProjectID = ""
    }
    func enableBackupNotifications() async throws {
        guard try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) else {
            throw DatabaseError.sqlite("알림 권한이 허용되지 않았습니다.")
        }
        UserDefaults.standard.set(true, forKey: "RavilBackupNotifications-" + owner)
        try await notifyBackupIfNeeded()
    }
    private func notifyBackupIfNeeded() async throws {
        guard UserDefaults.standard.bool(forKey: "RavilBackupNotifications-" + owner) else { return }
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.timeZone = TimeZone(identifier: "Asia/Seoul")
        let today = formatter.string(from: Date()), key = "RavilBackupLastReminder-" + owner
        guard UserDefaults.standard.string(forKey: key) != today,
              items("project").contains(where: { $0.payload.text("phase") != "archived" &&
                !$0.payload.text("examDate").isEmpty && $0.payload.text("examDate") < today }) else { return }
        let content = UNMutableNotificationContent()
        content.title = "RAVIL · 프로젝트 백업"; content.body = "종료일이 지난 프로젝트가 있어요. 백업과 보관을 확인해 주세요."
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "ravil-backup", content: content, trigger: nil))
        UserDefaults.standard.set(today, forKey: key)
    }
    func attachFile(_ url: URL, recordID: String) async throws {
        guard let credentials, let base = URL(string: baseURL), var record = get(recordID) else { throw DatabaseError.sqlite("파일을 연결하기 전에 로그인하고 기록을 저장해 주세요.") }
        let data = try Data(contentsOf: url)
        guard data.count <= 20 * 1024 * 1024 else { throw DatabaseError.sqlite("파일당 20MB까지 연결할 수 있습니다.") }
        let id = UUID().uuidString.lowercased()
        var request = URLRequest(url: base.appendingPathComponent("api/files/" + id))
        request.httpMethod = "PUT"; request.httpBody = data; request.timeoutInterval = 90
        request.setValue("Bearer " + credentials.token, forHTTPHeaderField: "Authorization")
        request.setValue(url.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .alphanumerics), forHTTPHeaderField: "X-File-Name")
        request.setValue(UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await network.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw DatabaseError.sqlite("파일을 저장하지 못했습니다. 원본은 이 기기에 보존됩니다.") }
        record.payload["fileIDs"] = .list(record.payload.list("fileIDs") + [id])
        _ = try put("record", record.payload, id: recordID); await sync()
    }
}
