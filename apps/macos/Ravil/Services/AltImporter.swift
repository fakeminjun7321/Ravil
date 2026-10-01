import CryptoKit
import Foundation
import SQLite3

struct AltSyncResult {
    let discovered: Int
    let imported: Int
    let unchanged: Int
}

private struct AltSegment {
    let providerID: String
    let start: Int
    let end: Int
    let text: String
    let speaker: String?
}

private struct AltNote {
    let id: String
    let title: String
    let date: String
    let status: String
    let type: String
    let folderID: String?
    let folderName: String?
    let transcriptID: String
    let transcriptJSON: String
    let audioPath: String?
    let recordingID: String?
    let summaryJSON: String?
    let slideComponentID: String?
    let slideText: String
    let slidePDFPath: String?
    let slideMIMEType: String?

    var contentHash: String {
        let payload = [title, date, status, type, folderID ?? "", folderName ?? "",
                       transcriptID, transcriptJSON, audioPath ?? "", summaryJSON ?? "",
                       slideComponentID ?? "", slideText, slidePDFPath ?? "", slideMIMEType ?? ""].joined(separator: "\u{1f}")
        return SHA256.hash(data: Data(payload.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func segments() throws -> [AltSegment] {
        guard !transcriptJSON.isEmpty else { return [] }
        let data = Data(transcriptJSON.utf8)
        guard let chunks = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw DatabaseError.sqlite("Alt 전사 구조가 예상한 JSON 배열이 아닙니다")
        }
        var result: [AltSegment] = []
        for (chunkIndex, chunk) in chunks.enumerated() {
            guard let pieces = chunk["segments"] as? [[String: Any]] else { continue }
            for (segmentIndex, piece) in pieces.enumerated() {
                guard let start = (piece["start"] as? NSNumber)?.intValue,
                      let end = (piece["end"] as? NSNumber)?.intValue,
                      end >= start,
                      let text = piece["text"] as? String else { continue }
                result.append(AltSegment(providerID: "\(transcriptID):\(chunkIndex):\(segmentIndex)",
                                         start: start, end: end, text: text,
                                         speaker: piece["speaker"] as? String))
            }
        }
        return result
    }

    var summaryText: String {
        guard let summaryJSON, let data = summaryJSON.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) else { return "" }
        func collect(_ value: Any) -> [String] {
            if let array = value as? [Any] { return array.flatMap(collect) }
            if let dictionary = value as? [String: Any] {
                return [dictionary["text"] as? String].compactMap { $0 } + collect(dictionary["children"] ?? [])
            }
            return []
        }
        return collect(root).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct AltReadFailure: Error {
    let code: Int32
    let detail: String
}

extension LibraryDatabase {
    func syncAlt(from sourceURL: URL = AppPaths.altDatabase) throws -> AltSyncResult {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            return AltSyncResult(discovered: 0, imported: 0, unchanged: 0)
        }
        let notes = try Self.readAltNotes(at: sourceURL)
        var imported = 0
        var unchanged = 0
        for note in notes {
            let existing = try rows("SELECT id, lecture_id FROM external_sources WHERE provider = 'alt' AND external_id = ?", values: [note.id]).first
            let snapshot = try rows("SELECT content_hash FROM alt_sync_snapshots WHERE external_id = ?", values: [note.id]).first?["content_hash"]
            let storedFolder = try rows("SELECT folder_id, folder_name, note_type FROM alt_note_folders WHERE note_id = ?",
                                        values: [note.id]).first
            let storedSlide = try rows("SELECT note_id FROM alt_slide_sources WHERE note_id = ?",
                                       values: [note.id]).first
            if snapshot == note.contentHash && existing != nil && storedFolder != nil
                && (note.slideComponentID == nil || storedSlide != nil) {
                unchanged += 1
                continue
            }
            let segments = try note.segments()
            let transcriptChanged = try existing.map {
                try !matchesStoredTranscript($0["id"] ?? "", segments: segments)
            } ?? true
            let summaryChanged = try existing.map {
                try providerSummary(for: $0["lecture_id"] ?? "") != note.summaryText
            } ?? false
            try importAlt(note, segments: segments, existing: existing,
                          transcriptChanged: transcriptChanged, summaryChanged: summaryChanged)
            imported += 1
        }
        return AltSyncResult(discovered: notes.count, imported: imported, unchanged: unchanged)
    }

    private func saveSnapshot(for note: AltNote) throws {
        try execute("""
        INSERT INTO alt_sync_snapshots (external_id, content_hash, synced_at) VALUES (?, ?, ?)
        ON CONFLICT(external_id) DO UPDATE SET content_hash = excluded.content_hash, synced_at = excluded.synced_at
        """, values: [note.id, note.contentHash, ISO8601DateFormatter().string(from: Date())])
    }

    private func matchesStoredTranscript(_ sourceID: String, segments: [AltSegment]) throws -> Bool {
        let stored = try rows("""
        SELECT provider_segment_id, start_ms, end_ms, text
        FROM transcript_segments WHERE external_source_id = ? ORDER BY ordinal
        """, values: [sourceID])
        guard stored.count == segments.count else { return false }
        return zip(stored, segments).allSatisfy { row, segment in
            row["provider_segment_id"] == segment.providerID &&
            row["start_ms"] == String(segment.start) &&
            row["end_ms"] == String(segment.end) &&
            row["text"] == segment.text
        }
    }

    private func importAlt(_ note: AltNote, segments: [AltSegment], existing: [String: String]?,
                           transcriptChanged: Bool, summaryChanged: Bool) throws {
        let lectureID = existing?["lecture_id"] ?? UUID().uuidString
        let sourceID = existing?["id"] ?? UUID().uuidString
        let now = ISO8601DateFormatter().string(from: Date())
        try execute("BEGIN IMMEDIATE")
        do {
            if existing == nil {
                try execute("""
                INSERT INTO lectures (id, title, lecture_date, source_status, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """, values: [lectureID, note.title, note.date, note.status, now, now])
                try execute("""
                INSERT INTO external_sources (id, lecture_id, provider, external_id, raw_payload_json, imported_at)
                VALUES (?, ?, 'alt', ?, ?, ?)
                """, values: [sourceID, lectureID, note.id, note.transcriptJSON.isEmpty ? "[]" : note.transcriptJSON, now])
            } else {
                try execute("UPDATE lectures SET title = ?, lecture_date = ?, source_status = ?, updated_at = ? WHERE id = ?",
                            values: [note.title, note.date, note.status, now, lectureID])
                try execute("UPDATE external_sources SET raw_payload_json = ?, imported_at = ? WHERE id = ?",
                            values: [note.transcriptJSON.isEmpty ? "[]" : note.transcriptJSON, now, sourceID])
            }
            try execute("""
            INSERT INTO alt_note_folders (note_id, lecture_id, folder_id, folder_name, note_type, synced_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(note_id) DO UPDATE SET
              lecture_id = excluded.lecture_id, folder_id = excluded.folder_id,
              folder_name = excluded.folder_name, note_type = excluded.note_type,
              synced_at = excluded.synced_at
            """, values: [note.id, lectureID, note.folderID, note.folderName, note.type, now])
            if let slideComponentID = note.slideComponentID {
                try execute("""
                INSERT INTO alt_slide_sources
                  (note_id, lecture_id, component_id, extracted_text, pdf_path, mime_type, synced_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(note_id) DO UPDATE SET
                  lecture_id = excluded.lecture_id, component_id = excluded.component_id,
                  extracted_text = excluded.extracted_text, pdf_path = excluded.pdf_path,
                  mime_type = excluded.mime_type, synced_at = excluded.synced_at
                """, values: [note.id, lectureID, slideComponentID, note.slideText,
                              note.slidePDFPath, note.slideMIMEType, now])
            } else {
                try execute("DELETE FROM alt_slide_sources WHERE note_id = ?", values: [note.id])
            }
            if transcriptChanged {
                let previous = try rows("""
                SELECT id, provider_segment_id, start_ms, end_ms, text
                FROM transcript_segments WHERE external_source_id = ? ORDER BY ordinal
                """, values: [sourceID])
                let byProviderID = Dictionary(uniqueKeysWithValues: previous.compactMap { row -> (String, [String: String])? in
                    guard let providerID = row["provider_segment_id"] else { return nil }
                    return (providerID, row)
                })
                try execute("UPDATE transcript_segments SET ordinal = -ordinal - 1 WHERE external_source_id = ?", values: [sourceID])
                for (index, segment) in segments.enumerated() {
                    if let old = byProviderID[segment.providerID], let segmentID = old["id"] {
                        if old["start_ms"] != String(segment.start) || old["end_ms"] != String(segment.end)
                            || old["text"] != segment.text {
                            try execute("DELETE FROM evidence WHERE transcript_segment_id = ?", values: [segmentID])
                        }
                        try execute("""
                        UPDATE transcript_segments SET ordinal = ?, start_ms = ?, end_ms = ?, text = ?, speaker_id = ?
                        WHERE id = ?
                        """, values: [String(index), String(segment.start), String(segment.end),
                                      segment.text, segment.speaker, segmentID])
                    } else {
                        try execute("""
                        INSERT INTO transcript_segments (id, lecture_id, external_source_id, provider_segment_id,
                          ordinal, start_ms, end_ms, text, speaker_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """, values: [UUID().uuidString, lectureID, sourceID, segment.providerID,
                                      String(index), String(segment.start), String(segment.end), segment.text, segment.speaker])
                    }
                }
                let currentIDs = Set(segments.map(\.providerID))
                for row in previous where !currentIDs.contains(row["provider_segment_id"] ?? "") {
                    guard let id = row["id"] else { continue }
                    try execute("DELETE FROM evidence WHERE transcript_segment_id = ?", values: [id])
                    try execute("DELETE FROM transcript_segments WHERE id = ?", values: [id])
                }
            }
            if existing != nil && (transcriptChanged || summaryChanged) {
                try markIntelligenceForReview(lectureID: lectureID)
            }
            if let audioPath = note.audioPath {
                let bytes = (try? FileManager.default.attributesOfItem(atPath: audioPath)[.size] as? Int) ?? 0
                try execute("""
                INSERT INTO audio_assets (id, lecture_id, external_source_id, provider_external_id, local_path, mime_type, size_bytes)
                VALUES (?, ?, ?, ?, ?, 'audio/mpeg', ?)
                ON CONFLICT(external_source_id) DO UPDATE SET local_path = excluded.local_path, size_bytes = excluded.size_bytes
                """, values: [UUID().uuidString, lectureID, sourceID, note.recordingID, audioPath, String(bytes)])
            }
            let payload: [String: Any] = ["altSummary": ["text": note.summaryText], "candidates": []]
            let rawSummary = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
            try execute("""
            INSERT INTO ai_artifacts (id, lecture_id, artifact_type, pipeline_version, payload_json, created_at)
            VALUES (?, ?, 'alt_summary_and_candidates', 'native-alt-import-v1', ?, ?)
            ON CONFLICT(lecture_id, artifact_type, pipeline_version) DO UPDATE SET
              payload_json = excluded.payload_json, created_at = excluded.created_at
            """, values: [UUID().uuidString, lectureID, rawSummary, now])
            try saveSnapshot(for: note)
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func markIntelligenceForReview(lectureID: String) throws {
        let artifacts = try rows("""
        SELECT id, payload_json FROM ai_artifacts WHERE lecture_id = ? AND artifact_type = 'lecture_intelligence'
        """, values: [lectureID])
        for artifact in artifacts {
            guard let id = artifact["id"], let raw = artifact["payload_json"],
                  let data = raw.data(using: .utf8),
                  var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            var verification = json["verification"] as? [String: Any] ?? [:]
            verification["sourceChanged"] = true
            json["verification"] = verification
            let updated = String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)
            try execute("UPDATE ai_artifacts SET payload_json = ? WHERE id = ?", values: [updated, id])
        }
    }

    private static func readAltNotes(at url: URL) throws -> [AltNote] {
        do {
            return try queryAltNotes(path: url.path, flags: SQLITE_OPEN_READONLY)
        } catch let failure as AltReadFailure where failure.code == SQLITE_CANTOPEN {
            // A closed Alt WAL database can lack -wal/-shm files. Normal read-only
            // SQLite access then fails when it wants to recreate the journal state.
            // Immutable access is safe only while there are no sidecar writes to miss.
            guard !FileManager.default.fileExists(atPath: url.path + "-wal"),
                  !FileManager.default.fileExists(atPath: url.path + "-shm") else {
                throw DatabaseError.sqlite("Alt DB를 현재 읽을 수 없습니다. Alt 작업이 끝난 뒤 다시 동기화하세요: \(failure.detail)")
            }
            return try queryAltNotes(path: url.absoluteString + "?immutable=1",
                                     flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_URI)
        }
    }

    private static func queryAltNotes(path: String, flags: Int32) throws -> [AltNote] {
        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(path, &database, flags, nil)
        guard openResult == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw AltReadFailure(code: openResult, detail: "Alt DB 열기 오류 \(openResult)")
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 1_500)
        func columnNames(_ table: String) throws -> Set<String> {
            var probe: OpaquePointer?
            guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &probe, nil) == SQLITE_OK,
                  let probe else {
                throw AltReadFailure(code: sqlite3_errcode(database), detail: "Alt 스키마 확인 오류")
            }
            defer { sqlite3_finalize(probe) }
            var names: Set<String> = []
            while sqlite3_step(probe) == SQLITE_ROW {
                if let raw = sqlite3_column_text(probe, 1) { names.insert(String(cString: raw)) }
            }
            return names
        }
        let noteColumns = try columnNames("lecture_notes")
        let folderColumns = try columnNames("folders")
        let fileColumns = try columnNames("file_metadata")
        let typeColumn = noteColumns.contains("type") ? "COALESCE(n.type, 'note')" : "'note'"
        let folderIDColumn = noteColumns.contains("folder_id") ? "n.folder_id" : "NULL"
        let folderNameColumn = folderColumns.contains("name") && noteColumns.contains("folder_id")
            ? "f.name" : "NULL"
        let folderJoin = folderColumns.contains("name") && noteColumns.contains("folder_id")
            ? "LEFT JOIN folders f ON f.id = n.folder_id AND f.deleted_at IS NULL" : ""
        let slideMIMEColumn = fileColumns.contains("mime_type") ? "sf.mime_type" : "NULL"
        let sql = """
        SELECT n.id, COALESCE(n.title, '') AS title, n.lecture_date,
               COALESCE(n.status, 'draft') AS status, \(typeColumn) AS note_type,
               \(folderIDColumn) AS folder_id, \(folderNameColumn) AS folder_name,
               t.id AS transcript_id, t.content_text AS transcript_json,
               fm.file_path AS audio_path, r.id AS recording_id,
               m.content_text AS summary_json,
               s.id AS slide_component_id, s.content_text AS slide_text,
               sf.file_path AS slide_pdf_path, \(slideMIMEColumn) AS slide_mime_type
        FROM lecture_notes n
        \(folderJoin)
        LEFT JOIN note_components t ON t.id = (
            SELECT c.id FROM note_components c
            WHERE c.note_id = n.id AND c.component_type = 'transcript' AND c.deleted_at IS NULL
            ORDER BY c.rowid DESC LIMIT 1
        )
        LEFT JOIN note_components r ON r.id = (
            SELECT c.id FROM note_components c
            WHERE c.note_id = n.id AND c.component_type = 'recording' AND c.deleted_at IS NULL
            ORDER BY c.rowid DESC LIMIT 1
        )
        LEFT JOIN file_metadata fm ON fm.inode = r.file_inode
        LEFT JOIN note_components m ON m.id = (
            SELECT c.id FROM note_components c
            WHERE c.note_id = n.id AND c.component_type = 'meeting_notes' AND c.deleted_at IS NULL
            ORDER BY c.rowid DESC LIMIT 1
        )
        LEFT JOIN note_components s ON s.id = (
            SELECT c.id FROM note_components c
            WHERE c.note_id = n.id AND c.component_type = 'slides' AND c.deleted_at IS NULL
            ORDER BY c.rowid DESC LIMIT 1
        )
        LEFT JOIN file_metadata sf ON sf.inode = s.file_inode
        WHERE n.deleted_at IS NULL
        """
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareResult == SQLITE_OK, let statement else {
            throw AltReadFailure(code: prepareResult, detail: String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        func value(_ column: Int32) -> String? {
            sqlite3_column_text(statement, column).map { String(cString: $0) }
        }
        var result: [AltNote] = []
        while true {
            let state = sqlite3_step(statement)
            if state == SQLITE_DONE { break }
            guard state == SQLITE_ROW else {
                throw AltReadFailure(code: state, detail: String(cString: sqlite3_errmsg(database)))
            }
            result.append(AltNote(id: value(0) ?? "", title: value(1) ?? "제목 없음",
                                  date: value(2) ?? "", status: value(3) ?? "draft",
                                  type: value(4) ?? "note", folderID: value(5), folderName: value(6),
                                  transcriptID: value(7) ?? "", transcriptJSON: value(8) ?? "",
                                  audioPath: value(9), recordingID: value(10), summaryJSON: value(11),
                                  slideComponentID: value(12), slideText: value(13) ?? "",
                                  slidePDFPath: value(14), slideMIMEType: value(15)))
        }
        return result
    }

    func providerSummary(for lectureID: String) throws -> String? {
        for row in try rows("""
        SELECT payload_json FROM ai_artifacts WHERE lecture_id = ? AND artifact_type = 'alt_summary_and_candidates'
        ORDER BY created_at DESC
        """, values: [lectureID]) {
            guard let raw = row["payload_json"], let data = raw.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let summary = json["altSummary"] as? [String: Any],
                  let text = summary["text"] as? String, !text.isEmpty else { continue }
            return text
        }
        return nil
    }
}
