import Foundation
import SQLite3

enum AltFolderSnapshotError: LocalizedError {
    case ambiguousWorkspace(String)
    case database(String)

    var errorDescription: String? {
        switch self {
        case .ambiguousWorkspace(let name):
            return "Alt의 '\(name)' 워크스페이스가 여러 계정 저장소에서 발견되어 폴더를 자동 선택할 수 없습니다."
        case .database(let detail):
            return "Alt 폴더 메타데이터를 읽을 수 없습니다: \(detail)"
        }
    }
}

enum AltFolderSnapshotReader {
    static func load(preferredWorkspaceName: String = "DSHS") throws -> AltFolderSnapshot? {
        let directory = AppPaths.altDatabase.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        let candidates = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ).filter { url in
            let filename = url.lastPathComponent
            guard filename.hasPrefix("powersync-store.account-"), filename.hasSuffix(".db") else {
                return false
            }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            return values?.isRegularFile == true && values?.isSymbolicLink != true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }

        var matchingURLs: [URL] = []
        for url in candidates {
            let database = try ReadOnlyAltMetadataDatabase(url: url)
            let count = try database.workspaceCount(named: preferredWorkspaceName)
            if count > 1 { throw AltFolderSnapshotError.ambiguousWorkspace(preferredWorkspaceName) }
            if count == 1 { matchingURLs.append(url) }
        }
        guard matchingURLs.count <= 1 else {
            throw AltFolderSnapshotError.ambiguousWorkspace(preferredWorkspaceName)
        }
        guard let sourceURL = matchingURLs.first else { return nil }

        let database = try ReadOnlyAltMetadataDatabase(url: sourceURL)
        return try database.snapshot(workspaceName: preferredWorkspaceName, sourceURL: sourceURL)
    }
}

private final class ReadOnlyAltMetadataDatabase {
    private var handle: OpaquePointer?

    init(url: URL) throws {
        let result = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, handle != nil else {
            let detail = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite \(result)"
            if let handle { sqlite3_close(handle) }
            handle = nil
            throw AltFolderSnapshotError.database(detail)
        }
        sqlite3_busy_timeout(handle, 1_500)
        guard sqlite3_exec(handle, "PRAGMA query_only=ON", nil, nil, nil) == SQLITE_OK else {
            throw databaseError()
        }
    }

    deinit { if let handle { sqlite3_close(handle) } }

    func workspaceCount(named name: String) throws -> Int {
        var count = 0
        try query("SELECT COUNT(*) FROM workspaces WHERE name = ? AND deleted_at IS NULL", value: name) {
            count = Int(sqlite3_column_int64($0, 0))
        }
        return count
    }

    func snapshot(workspaceName: String, sourceURL: URL) throws -> AltFolderSnapshot {
        try execute("BEGIN")
        do {
            guard try workspaceCount(named: workspaceName) == 1 else {
                throw AltFolderSnapshotError.ambiguousWorkspace(workspaceName)
            }

            var notes: [AltNoteMetadata] = []
            try query("""
                SELECT id, title, lecture_date, type, folder_id
                FROM lecture_notes WHERE deleted_at IS NULL
                ORDER BY lecture_date DESC, title, id
                """) { row in
                guard let id = Self.text(row, 0), !id.isEmpty else { return }
                notes.append(AltNoteMetadata(
                    id: id,
                    title: Self.text(row, 1) ?? "",
                    date: Self.text(row, 2) ?? "",
                    type: Self.text(row, 3) ?? "",
                    folderID: Self.text(row, 4)
                ))
            }

            let directCounts = Dictionary(grouping: notes.compactMap { note -> (String, String)? in
                guard let folderID = note.folderID else { return nil }
                return (folderID, note.id)
            }, by: { $0.0 }).mapValues(\.count)
            var folders: [AltFolderMetadata] = []
            try query("""
                SELECT id, name, parent_id, color_hue
                FROM folders WHERE deleted_at IS NULL
                ORDER BY name, id
                """) { row in
                guard let id = Self.text(row, 0), !id.isEmpty else { return }
                let hue = sqlite3_column_type(row, 3) == SQLITE_NULL
                    ? nil : Int(sqlite3_column_int64(row, 3))
                folders.append(AltFolderMetadata(
                    id: id,
                    name: Self.text(row, 1) ?? "",
                    parentID: Self.text(row, 2),
                    colorHue: hue,
                    noteCount: directCounts[id] ?? 0
                ))
            }
            try execute("COMMIT")
            return AltFolderSnapshot(sourceURL: sourceURL, workspaceName: workspaceName,
                                     folders: folders, notes: notes)
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func query(_ sql: String, value: String? = nil,
                       row: (OpaquePointer) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw databaseError() }
        defer { sqlite3_finalize(statement) }
        if let value {
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            guard sqlite3_bind_text(statement, 1, value, -1, transient) == SQLITE_OK else {
                throw databaseError()
            }
        }
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return }
            guard result == SQLITE_ROW else { throw databaseError() }
            try row(statement)
        }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw databaseError()
        }
    }

    private func databaseError() -> AltFolderSnapshotError {
        .database(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "알 수 없는 SQLite 오류")
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }
}
