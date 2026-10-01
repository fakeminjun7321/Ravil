import Foundation

struct DrivePDF: Equatable {
    let id: String
    let name: String
    let mimeType: String
    let revision: String?
    let modifiedAt: String?
    let size: Int64?
}

protocol GoodnotesDriveSource {
    func validateRoot(id: String) async throws
    func children(of folderID: String) async throws -> [DrivePDF]
    func downloadPDF(id: String, to destination: URL) async throws
}

extension GoodnotesDriveSource {
    func validateRoot(id: String) async throws { }
}

struct GoodnotesSyncReport {
    let discoveredPDFs: Int
    let downloadedPDFs: Int
    let unchangedPDFs: Int
    let imported: GoodnotesImportReport?
    let reclassifiedMaterials: Int

    var libraryChanged: Bool { imported != nil || reclassifiedMaterials > 0 }
}

enum GoodnotesSyncError: LocalizedError {
    case invalidFolder
    case unsafeName(String)
    case duplicatePath(String)
    case tooManyFiles
    case tooDeep
    case fileTooLarge(String)
    case invalidResponse
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidFolder: return "선택한 중간고사 폴더를 읽을 수 없습니다."
        case .unsafeName(let value): return "안전하지 않은 Drive 파일 이름입니다: \(value)"
        case .duplicatePath(let value): return "Drive 폴더에 같은 상대 경로가 중복됩니다: \(value)"
        case .tooManyFiles: return "한 번에 확인할 수 있는 자료 수를 초과했습니다."
        case .tooDeep: return "중간고사 폴더의 하위 폴더 깊이가 너무 큽니다."
        case .fileTooLarge(let value): return "PDF가 설정된 크기 제한을 넘었습니다: \(value)"
        case .invalidResponse: return "Drive 응답 형식이 올바르지 않습니다."
        case .http(let code): return "Google Drive 요청에 실패했습니다 (HTTP \(code))."
        }
    }
}

struct GoodnotesAutoSync {
    private let source: any GoodnotesDriveSource
    private let database: LibraryDatabase
    private let rootFolderID: String
    private let maxFiles = 2_000
    private let maxFileSize: Int64 = 500 * 1_024 * 1_024

    init(source: any GoodnotesDriveSource, database: LibraryDatabase, rootFolderID: String) {
        self.source = source
        self.database = database
        self.rootFolderID = rootFolderID
    }

    func run() async throws -> GoodnotesSyncReport {
        guard Self.isDriveID(rootFolderID) else { throw GoodnotesSyncError.invalidFolder }
        try await source.validateRoot(id: rootFolderID)
        var pending: [(id: String, path: String, depth: Int)] = [(rootFolderID, "", 0)]
        var visitedFolders = Set<String>()
        var paths = Set<String>()
        var files: [(file: DrivePDF, path: String)] = []
        // Finish enumeration before downloading or importing. A transient listing error
        // must never be mistaken for a complete, empty Goodnotes snapshot.
        while !pending.isEmpty {
            try Task.checkCancellation()
            let folder = pending.removeFirst()
            guard visitedFolders.insert(folder.id).inserted else { continue }
            guard folder.depth <= 20 else { throw GoodnotesSyncError.tooDeep }
            for child in try await source.children(of: folder.id) {
                guard Self.isDriveID(child.id) else { throw GoodnotesSyncError.invalidResponse }
                let name = try Self.safeComponent(child.name)
                let path = folder.path.isEmpty ? name : folder.path + "/" + name
                if child.mimeType == "application/vnd.google-apps.folder" {
                    pending.append((child.id, path, folder.depth + 1))
                } else if child.mimeType == "application/pdf" && name.lowercased().hasSuffix(".pdf") {
                    guard let size = child.size, size > 0, size <= maxFileSize else {
                        throw GoodnotesSyncError.fileTooLarge(path)
                    }
                    let key = path.precomposedStringWithCanonicalMapping.lowercased(with: Locale(identifier: "en_US_POSIX"))
                    guard paths.insert(key).inserted else { throw GoodnotesSyncError.duplicatePath(path) }
                    files.append((child, path))
                    guard files.count <= maxFiles else { throw GoodnotesSyncError.tooManyFiles }
                }
            }
        }
        let existing = try database.goodnotesObservedSources(rootFolderID: rootFolderID)
        let changed = files.filter { item in
            guard let old = existing[item.file.id],
                  let revision = item.file.revision, !revision.isEmpty else { return true }
            return old.revision != revision || old.relativePath != item.path
        }
        guard !changed.isEmpty else {
            let reclassified = try database.reclassifyGoodnotesMaterials()
            return GoodnotesSyncReport(discoveredPDFs: files.count, downloadedPDFs: 0,
                                       unchangedPDFs: files.count, imported: nil,
                                       reclassifiedMaterials: reclassified)
        }
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("RavilDriveSync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        var entries: [GoodnotesImportEntry] = []
        for (index, item) in changed.enumerated() {
            try Task.checkCancellation()
            let target = temporary.appendingPathComponent("\(index).pdf")
            try await source.downloadPDF(id: item.file.id, to: target)
            let actualSize = (try target.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            guard actualSize > 0, actualSize <= maxFileSize else {
                throw GoodnotesSyncError.fileTooLarge(item.path)
            }
            entries.append(GoodnotesImportEntry(
                driveFileID: item.file.id, revisionID: item.file.revision,
                relativePath: item.path, localPDFPath: target.path,
                sourceURL: "https://drive.google.com/file/d/\(item.file.id)/view",
                sourceModifiedAt: item.file.modifiedAt, subject: nil, documentKind: nil))
        }
        try Task.checkCancellation()
        let imported = try database.importGoodnotesMidterm(
            GoodnotesImportManifest(midtermRootFolderID: rootFolderID, entries: entries))
        let reclassified = try database.reclassifyGoodnotesMaterials()
        return GoodnotesSyncReport(discoveredPDFs: files.count, downloadedPDFs: changed.count,
                                   unchangedPDFs: files.count - changed.count, imported: imported,
                                   reclassifiedMaterials: reclassified)
    }

    private static func safeComponent(_ name: String) throws -> String {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
              name.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw GoodnotesSyncError.unsafeName(name)
        }
        return name.precomposedStringWithCanonicalMapping
    }

    private static func isDriveID(_ value: String) -> Bool {
        !value.isEmpty && value.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
    }
}

struct GoogleDrivePDFSource: GoodnotesDriveSource {
    let accessToken: String
    var session: URLSession = URLSession(configuration: .ephemeral)

    func validateRoot(id: String) async throws {
        guard id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
            throw GoodnotesSyncError.invalidFolder
        }
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(id)")!
        components.queryItems = [URLQueryItem(name: "fields", value: "id,mimeType,trashed,capabilities(canListChildren)"),
                                 URLQueryItem(name: "supportsAllDrives", value: "true")]
        let (data, response) = try await session.data(for: authorizedRequest(components.url!))
        guard let http = response as? HTTPURLResponse else { throw GoodnotesSyncError.invalidResponse }
        guard http.statusCode == 200 else { throw GoodnotesSyncError.http(http.statusCode) }
        let folder = try JSONDecoder().decode(FolderEntry.self, from: data)
        guard folder.id == id, folder.mimeType == "application/vnd.google-apps.folder",
              folder.trashed != true, folder.capabilities?.canListChildren != false else {
            throw GoodnotesSyncError.invalidFolder
        }
    }

    func children(of folderID: String) async throws -> [DrivePDF] {
        var result: [DrivePDF] = []
        var pageToken: String?
        var seenTokens = Set<String>()
        repeat {
            var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
            components.queryItems = [
                URLQueryItem(name: "q", value: "'\(folderID)' in parents and trashed = false"),
                URLQueryItem(name: "fields", value: "nextPageToken,files(id,name,mimeType,headRevisionId,version,modifiedTime,size)"),
                URLQueryItem(name: "pageSize", value: "1000"),
                URLQueryItem(name: "supportsAllDrives", value: "true"),
                URLQueryItem(name: "includeItemsFromAllDrives", value: "true")
            ]
            if let pageToken { components.queryItems?.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let (data, response) = try await session.data(for: authorizedRequest(components.url!))
            guard let http = response as? HTTPURLResponse else { throw GoodnotesSyncError.invalidResponse }
            guard http.statusCode == 200 else { throw GoodnotesSyncError.http(http.statusCode) }
            let page = try JSONDecoder().decode(FilePage.self, from: data)
            result += page.files.map { file in
                DrivePDF(id: file.id, name: file.name, mimeType: file.mimeType,
                         revision: file.headRevisionId ?? file.version,
                         modifiedAt: file.modifiedTime, size: file.size.flatMap(Int64.init))
            }
            pageToken = page.nextPageToken
            if let pageToken, !seenTokens.insert(pageToken).inserted { throw GoodnotesSyncError.invalidResponse }
        } while pageToken != nil
        return result
    }

    func downloadPDF(id: String, to destination: URL) async throws {
        guard id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
            throw GoodnotesSyncError.invalidResponse
        }
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(id)")!
        components.queryItems = [URLQueryItem(name: "alt", value: "media"),
                                 URLQueryItem(name: "supportsAllDrives", value: "true")]
        let (temporary, response) = try await session.download(for: authorizedRequest(components.url!))
        guard let http = response as? HTTPURLResponse else { throw GoodnotesSyncError.invalidResponse }
        guard http.statusCode == 200 else { throw GoodnotesSyncError.http(http.statusCode) }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    private func authorizedRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60
        return request
    }

    private struct FilePage: Decodable {
        let nextPageToken: String?
        let files: [FileEntry]
    }

    private struct FolderEntry: Decodable {
        let id: String
        let mimeType: String
        let trashed: Bool?
        let capabilities: Capabilities?
        struct Capabilities: Decodable { let canListChildren: Bool? }
    }

    private struct FileEntry: Decodable {
        let id: String
        let name: String
        let mimeType: String
        let headRevisionId: String?
        let version: String?
        let modifiedTime: String?
        let size: String?
    }
}
