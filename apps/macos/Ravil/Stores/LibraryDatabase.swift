import Foundation
import SQLite3
import PDFKit
import CryptoKit
import UniformTypeIdentifiers

enum DatabaseError: LocalizedError {
    case sqlite(String)
    var errorDescription: String? {
        switch self { case .sqlite(let message): return message }
    }
}

final class LibraryDatabase {
    private var handle: OpaquePointer?
    let location: URL

    init(location: URL = AppPaths.database, importLegacy: Bool = true) throws {
        self.location = location
        try FileManager.default.createDirectory(at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: location.deletingLastPathComponent().path)
        let existingSize = (try? FileManager.default.attributesOfItem(atPath: location.path)[.size] as? Int) ?? 0
        if importLegacy && existingSize == 0
            && FileManager.default.fileExists(atPath: AppPaths.legacyDatabase.path) {
            try Self.backup(from: AppPaths.legacyDatabase, to: location)
        }
        guard sqlite3_open_v2(location.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw DatabaseError.sqlite("개인 DB를 열 수 없습니다: \(location.path)")
        }
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA busy_timeout = 5000")
        try createTables()
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: location.path)
    }

    deinit { if let handle { sqlite3_close(handle) } }

    static func backup(from source: URL, to destination: URL) throws {
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".ravil-migration-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: staging) }
        do {
            try copySQLite(from: source, to: staging, sourceFlags: SQLITE_OPEN_READONLY)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            // Some legacy SQLite databases in WAL mode cannot open through a read-only
            // connection when their journal files are absent. A normal connection can
            // produce a consistent backup without changing logical source records.
            try copySQLite(from: source, to: staging, sourceFlags: SQLITE_OPEN_READWRITE)
        }
        try verifySQLite(at: staging)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.path)
        if FileManager.default.fileExists(atPath: destination.path) {
            let size = (try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int) ?? -1
            guard size == 0 else { throw DatabaseError.sqlite("기존 Ravil DB가 있어 이전 결과를 덮어쓸 수 없습니다") }
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: staging, to: destination)
    }

    private static func copySQLite(from source: URL, to destination: URL, sourceFlags: Int32) throws {
        var input: OpaquePointer?
        var output: OpaquePointer?
        guard sqlite3_open_v2(source.path, &input, sourceFlags, nil) == SQLITE_OK,
              sqlite3_open_v2(destination.path, &output, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            if let input { sqlite3_close(input) }
            if let output { sqlite3_close(output) }
            throw DatabaseError.sqlite("기존 Lecture OS 데이터를 읽을 수 없습니다")
        }
        defer { sqlite3_close(input); sqlite3_close(output) }
        guard let transfer = sqlite3_backup_init(output, "main", input, "main") else {
            throw DatabaseError.sqlite("기존 데이터 복사를 시작할 수 없습니다")
        }
        var result: Int32 = SQLITE_OK
        var busyCount = 0
        repeat {
            result = sqlite3_backup_step(transfer, 64)
            if result == SQLITE_BUSY || result == SQLITE_LOCKED {
                busyCount += 1
                if busyCount <= 3 { Thread.sleep(forTimeInterval: 0.1) }
            }
        } while result == SQLITE_OK || ((result == SQLITE_BUSY || result == SQLITE_LOCKED) && busyCount <= 3)
        let errorText = String(cString: sqlite3_errmsg(output))
        sqlite3_backup_finish(transfer)
        guard result == SQLITE_DONE else {
            throw DatabaseError.sqlite("기존 데이터 복사가 완료되지 않았습니다 (SQLite \(result): \(errorText))")
        }
    }

    private static func verifySQLite(at url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let database else { throw DatabaseError.sqlite("이전된 DB를 확인할 수 없습니다") }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA integrity_check", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw DatabaseError.sqlite("이전된 DB 무결성 검사가 실패했습니다") }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let raw = sqlite3_column_text(statement, 0),
              String(cString: raw) == "ok" else { throw DatabaseError.sqlite("이전된 DB의 무결성이 확인되지 않았습니다") }
    }

    private func createTables() throws {
        try execute("""
        CREATE TABLE IF NOT EXISTS lectures (
            id TEXT PRIMARY KEY, title TEXT NOT NULL, lecture_date TEXT NOT NULL,
            source_status TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
            started_at TEXT, course_id TEXT
        );
        CREATE TABLE IF NOT EXISTS courses (id TEXT PRIMARY KEY, semester_id TEXT, name TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS external_sources (
            id TEXT PRIMARY KEY, lecture_id TEXT NOT NULL, provider TEXT NOT NULL,
            external_id TEXT NOT NULL, raw_payload_json TEXT NOT NULL, imported_at TEXT NOT NULL,
            UNIQUE(provider, external_id)
        );
        CREATE TABLE IF NOT EXISTS audio_assets (
            id TEXT PRIMARY KEY, lecture_id TEXT NOT NULL, external_source_id TEXT NOT NULL,
            provider_external_id TEXT, local_path TEXT, mime_type TEXT, size_bytes INTEGER,
            UNIQUE(external_source_id)
        );
        CREATE TABLE IF NOT EXISTS transcript_segments (
            id TEXT PRIMARY KEY, lecture_id TEXT NOT NULL, external_source_id TEXT NOT NULL,
            provider_segment_id TEXT NOT NULL, ordinal INTEGER NOT NULL,
            start_ms INTEGER NOT NULL, end_ms INTEGER NOT NULL, text TEXT NOT NULL,
            speaker_id TEXT, UNIQUE(external_source_id, ordinal)
        );
        CREATE TABLE IF NOT EXISTS transcript_superseded_segments (
            segment_id TEXT PRIMARY KEY REFERENCES transcript_segments(id),
            replacement_source_id TEXT NOT NULL,
            superseded_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS evidence (
            id TEXT PRIMARY KEY, lecture_id TEXT NOT NULL,
            transcript_segment_id TEXT NOT NULL REFERENCES transcript_segments(id) ON DELETE CASCADE,
            kind TEXT NOT NULL, quote TEXT NOT NULL, start_ms INTEGER NOT NULL,
            end_ms INTEGER NOT NULL, pipeline_version TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS ai_artifacts (
            id TEXT PRIMARY KEY, lecture_id TEXT NOT NULL, artifact_type TEXT NOT NULL,
            pipeline_version TEXT NOT NULL, payload_json TEXT NOT NULL, created_at TEXT NOT NULL,
            UNIQUE(lecture_id, artifact_type, pipeline_version)
        );
        CREATE TABLE IF NOT EXISTS course_materials (
            id TEXT PRIMARY KEY, course_id TEXT, lecture_id TEXT, provider TEXT NOT NULL,
            external_id TEXT NOT NULL, external_url TEXT, file_name TEXT NOT NULL,
            mime_type TEXT NOT NULL, local_path TEXT, content_hash TEXT,
            source_modified_at TEXT, version INTEGER NOT NULL, page_count INTEGER,
            has_text_layer INTEGER, status TEXT NOT NULL, ingested_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS material_pages (
            id TEXT PRIMARY KEY, material_id TEXT NOT NULL, page_number INTEGER NOT NULL,
            text TEXT NOT NULL, text_hash TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS material_page_ocr (
            page_id TEXT PRIMARY KEY REFERENCES material_pages(id),
            text TEXT NOT NULL,
            mean_confidence REAL NOT NULL,
            status TEXT NOT NULL,
            engine_version TEXT NOT NULL,
            processed_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS material_page_ocr_review (
            page_id TEXT PRIMARY KEY REFERENCES material_page_ocr(page_id),
            corrected_text TEXT NOT NULL,
            approved_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS goodnotes_documents (
            id TEXT PRIMARY KEY,
            midterm_root_folder_id TEXT NOT NULL,
            relative_path TEXT NOT NULL,
            path_key TEXT NOT NULL,
            subject TEXT NOT NULL,
            document_kind TEXT NOT NULL,
            current_material_id TEXT REFERENCES course_materials(id),
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            UNIQUE(midterm_root_folder_id, path_key)
        );
        CREATE TABLE IF NOT EXISTS goodnotes_classifications (
            document_id TEXT PRIMARY KEY REFERENCES goodnotes_documents(id),
            subject_source TEXT NOT NULL,
            kind_source TEXT NOT NULL,
            teacher_name TEXT,
            confidence REAL NOT NULL,
            needs_review INTEGER NOT NULL,
            classified_at TEXT NOT NULL
        );
        CREATE UNIQUE INDEX IF NOT EXISTS goodnotes_current_material
            ON goodnotes_documents(current_material_id) WHERE current_material_id IS NOT NULL;
        CREATE TABLE IF NOT EXISTS goodnotes_versions (
            material_id TEXT PRIMARY KEY REFERENCES course_materials(id),
            document_id TEXT NOT NULL REFERENCES goodnotes_documents(id),
            version INTEGER NOT NULL,
            content_hash TEXT NOT NULL,
            UNIQUE(document_id, version),
            UNIQUE(document_id, content_hash)
        );
        CREATE TABLE IF NOT EXISTS goodnotes_source_observations (
            observation_key TEXT PRIMARY KEY,
            document_id TEXT NOT NULL REFERENCES goodnotes_documents(id),
            material_id TEXT NOT NULL REFERENCES course_materials(id),
            midterm_root_folder_id TEXT NOT NULL,
            drive_file_id TEXT NOT NULL,
            revision_id TEXT,
            relative_path TEXT NOT NULL,
            source_url TEXT NOT NULL,
            source_modified_at TEXT,
            observed_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS goodnotes_observations_file
            ON goodnotes_source_observations(midterm_root_folder_id, drive_file_id);
        CREATE TABLE IF NOT EXISTS exam_scopes (
            id TEXT PRIMARY KEY, title TEXT NOT NULL, exam_date TEXT,
            created_at TEXT NOT NULL, updated_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS exam_scope_materials (
            scope_id TEXT NOT NULL REFERENCES exam_scopes(id) ON DELETE CASCADE,
            material_id TEXT NOT NULL REFERENCES course_materials(id),
            start_page INTEGER NOT NULL, end_page INTEGER NOT NULL,
            PRIMARY KEY(scope_id, material_id)
        );
        CREATE TABLE IF NOT EXISTS quiz_cards (
            id TEXT PRIMARY KEY, scope_id TEXT NOT NULL REFERENCES exam_scopes(id) ON DELETE CASCADE,
            question TEXT NOT NULL, answer TEXT NOT NULL,
            source_material_id TEXT NOT NULL REFERENCES course_materials(id),
            source_page INTEGER NOT NULL,
            created_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS quiz_reviews (
            id TEXT PRIMARY KEY, card_id TEXT NOT NULL REFERENCES quiz_cards(id) ON DELETE CASCADE,
            grade TEXT NOT NULL, reviewed_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS quiz_reviews_by_card ON quiz_reviews(card_id, reviewed_at);
        CREATE TABLE IF NOT EXISTS personal_notes (
            id TEXT PRIMARY KEY, title TEXT NOT NULL, body TEXT NOT NULL,
            created_at TEXT NOT NULL, updated_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS lecture_memos (
            lecture_id TEXT PRIMARY KEY REFERENCES lectures(id) ON DELETE CASCADE,
            body TEXT NOT NULL, updated_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS alt_sync_snapshots (
            external_id TEXT PRIMARY KEY, content_hash TEXT NOT NULL, synced_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS alt_note_folders (
            note_id TEXT PRIMARY KEY,
            lecture_id TEXT NOT NULL UNIQUE REFERENCES lectures(id) ON DELETE CASCADE,
            folder_id TEXT,
            folder_name TEXT,
            note_type TEXT NOT NULL,
            synced_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS alt_slide_sources (
            note_id TEXT PRIMARY KEY,
            lecture_id TEXT NOT NULL UNIQUE REFERENCES lectures(id) ON DELETE CASCADE,
            component_id TEXT NOT NULL,
            extracted_text TEXT NOT NULL,
            pdf_path TEXT,
            mime_type TEXT,
            synced_at TEXT NOT NULL
        );
        """)
    }

    func execute(_ sql: String, values: [String?] = []) throws {
        if values.isEmpty {
            var message: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(handle, sql, nil, nil, &message) == SQLITE_OK else {
                let detail = message.map { String(cString: $0) } ?? "알 수 없는 DB 오류"
                sqlite3_free(message)
                throw DatabaseError.sqlite(detail)
            }
            return
        }
        try withStatement(sql, values: values) { statement in
            guard sqlite3_step(statement) == SQLITE_DONE else { throw currentError() }
        }
    }

    private func withStatement<T>(_ sql: String, values: [String?] = [], body: (OpaquePointer) throws -> T) throws -> T {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw currentError() }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            let slot = Int32(index + 1)
            if let value {
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                guard sqlite3_bind_text(statement, slot, value, -1, transient) == SQLITE_OK else { throw currentError() }
            } else {
                guard sqlite3_bind_null(statement, slot) == SQLITE_OK else { throw currentError() }
            }
        }
        return try body(statement)
    }

    private func currentError() -> DatabaseError {
        DatabaseError.sqlite(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "알 수 없는 DB 오류")
    }

    func rows(_ sql: String, values: [String?] = []) throws -> [[String: String]] {
        try withStatement(sql, values: values) { statement in
            var result: [[String: String]] = []
            while true {
                let state = sqlite3_step(statement)
                if state == SQLITE_DONE { break }
                guard state == SQLITE_ROW else { throw currentError() }
                var row: [String: String] = [:]
                for column in 0..<sqlite3_column_count(statement) {
                    if let raw = sqlite3_column_text(statement, column) {
                        row[String(cString: sqlite3_column_name(statement, column))] = String(cString: raw)
                    }
                }
                result.append(row)
            }
            return result
        }
    }

    func lectures() throws -> [LectureItem] {
        try rows("""
        SELECT l.id, l.title, l.lecture_date, l.course_id, l.source_status,
               COALESCE(c.name, '') AS course,
               a.local_path AS audio_path, af.folder_name AS alt_folder_name,
               af.note_type AS alt_note_type,
               EXISTS(SELECT 1 FROM external_sources rs WHERE rs.lecture_id = l.id
                      AND rs.provider IN ('ravil_recorder', 'ravil_audio_import')) AS can_transcribe
        FROM lectures l LEFT JOIN courses c ON c.id = l.course_id
        LEFT JOIN audio_assets a ON a.lecture_id = l.id
        LEFT JOIN alt_note_folders af ON af.lecture_id = l.id
        ORDER BY l.lecture_date DESC, l.created_at DESC
        """).map { row in
            LectureItem(id: row["id"] ?? "", title: row["title"] ?? "",
                        date: row["lecture_date"] ?? "", courseID: row["course_id"],
                        course: row["course"] ?? "",
                        audioPath: row["audio_path"], status: row["source_status"] ?? "",
                        altFolderName: row["alt_folder_name"], altNoteType: row["alt_note_type"],
                        canTranscribe: row["can_transcribe"] == "1")
        }
    }

    func courses() throws -> [CourseItem] {
        try rows("SELECT id, name FROM courses ORDER BY name").map {
            CourseItem(id: $0["id"] ?? "", name: $0["name"] ?? "")
        }
    }

    func transcript(for lectureID: String) throws -> [TranscriptItem] {
        try rows("""
        SELECT id, start_ms, end_ms, text, speaker_id FROM transcript_segments
        WHERE lecture_id = ? AND NOT EXISTS (
            SELECT 1 FROM transcript_superseded_segments old WHERE old.segment_id = transcript_segments.id
        ) ORDER BY ordinal
        """, values: [lectureID]).map { row in
            TranscriptItem(id: row["id"] ?? "", startMilliseconds: Int(row["start_ms"] ?? "") ?? 0,
                           endMilliseconds: Int(row["end_ms"] ?? "") ?? 0, text: row["text"] ?? "",
                           speaker: row["speaker_id"].flatMap { $0.isEmpty ? nil : $0 })
        }
    }

    func altSlideSource(for lectureID: String) throws -> AltSlideSource? {
        guard let row = try rows("""
        SELECT note_id, component_id, extracted_text, pdf_path, mime_type
        FROM alt_slide_sources WHERE lecture_id = ? LIMIT 1
        """, values: [lectureID]).first,
              let noteID = row["note_id"], let componentID = row["component_id"] else { return nil }
        return AltSlideSource(noteID: noteID, componentID: componentID,
                              extractedText: row["extracted_text"] ?? "",
                              localPDFPath: row["pdf_path"], mimeType: row["mime_type"])
    }

    func intelligence(for lectureID: String) throws -> LectureIntelligence? {
        guard let data = try rows("""
        SELECT payload_json FROM ai_artifacts WHERE lecture_id = ? AND artifact_type = 'lecture_intelligence'
        ORDER BY created_at DESC LIMIT 1
        """, values: [lectureID]).first?["payload_json"]?.data(using: .utf8) else { return nil }
        return try JSONDecoder().decode(LectureIntelligence.self, from: data)
    }

    func materials() throws -> [MaterialItem] {
        try rows("""
        SELECT m.id, m.lecture_id, m.course_id, m.file_name, m.status, m.page_count, m.local_path, m.external_url,
               COALESCE(g.subject, c.name, '') AS course, g.document_kind,
               gc.teacher_name, gc.needs_review
        FROM course_materials m
        LEFT JOIN courses c ON c.id = m.course_id
        LEFT JOIN goodnotes_documents g ON g.current_material_id = m.id
        LEFT JOIN goodnotes_classifications gc ON gc.document_id = g.id
        WHERE m.provider <> 'goodnotes_drive_pdf' OR g.id IS NOT NULL
        ORDER BY m.ingested_at DESC
        """).map { row in
            MaterialItem(id: row["id"] ?? "", lectureID: row["lecture_id"], courseID: row["course_id"],
                         title: row["file_name"] ?? "",
                         course: row["course"] ?? "", status: row["status"] ?? "",
                         pageCount: row["page_count"].flatMap(Int.init),
                         localPath: row["local_path"], externalURL: row["external_url"],
                         documentKind: row["document_kind"], teacherName: row["teacher_name"],
                         classificationNeedsReview: row["needs_review"] == "1")
        }
    }

    func goodnotesVersions(for materialID: String) throws -> [GoodnotesVersionItem] {
        guard let documentID = try rows("SELECT document_id FROM goodnotes_versions WHERE material_id = ? LIMIT 1",
                                        values: [materialID]).first?["document_id"] else { return [] }
        return try rows("""
            SELECT v.material_id, v.version, v.content_hash, m.page_count, m.local_path,
                   m.source_modified_at
            FROM goodnotes_versions v JOIN course_materials m ON m.id = v.material_id
            WHERE v.document_id = ? ORDER BY v.version DESC
            """, values: [documentID]).compactMap { row in
                guard let id = row["material_id"], let path = row["local_path"],
                      let hash = row["content_hash"],
                      let version = row["version"].flatMap(Int.init),
                      let pages = row["page_count"].flatMap(Int.init) else { return nil }
                return GoodnotesVersionItem(materialID: id, version: version,
                                            pageCount: pages, localPath: path,
                                            contentHash: hash,
                                            sourceModifiedAt: row["source_modified_at"])
            }
    }

    func goodnotesChangeSummary(for materialID: String) throws -> GoodnotesChangeSummary? {
        let versions = try goodnotesVersions(for: materialID)
        guard versions.count >= 2 else { return nil }
        let current = versions[0]
        let previous = versions[1]
        func pageRows(for materialID: String) throws -> [[String: String]] {
            try rows("""
                SELECT text_hash, length(trim(text)) AS text_length
                FROM material_pages WHERE material_id = ? ORDER BY page_number
                """, values: [materialID])
        }
        let oldPages = try pageRows(for: previous.materialID)
        let newPages = try pageRows(for: current.materialID)
        var added: [Int] = []
        // Only name page numbers when every old page is still present unchanged.
        // Repeated/blank page text makes an insertion position ambiguous.
        let oldHashes = oldPages.compactMap { $0["text_hash"] }
        let newHashes = newPages.compactMap { $0["text_hash"] }
        if newHashes.count > oldHashes.count,
           oldHashes.count == oldPages.count, newHashes.count == newPages.count,
           Set(oldHashes).count == oldHashes.count,
           oldPages.allSatisfy({ Int($0["text_length"] ?? "0") ?? 0 > 0 }),
           newPages.allSatisfy({ Int($0["text_length"] ?? "0") ?? 0 > 0 }) {
            var oldIndex = 0
            var newIndex = 0
            var candidates: [Int] = []
            while newIndex < newHashes.count {
                if oldIndex < oldHashes.count && newHashes[newIndex] == oldHashes[oldIndex] {
                    oldIndex += 1
                } else {
                    candidates.append(newIndex + 1)
                }
                newIndex += 1
            }
            if oldIndex == oldHashes.count { added = candidates }
        }
        return GoodnotesChangeSummary(previousVersion: previous.version,
                                      currentVersion: current.version,
                                      previousPages: previous.pageCount,
                                      currentPages: current.pageCount,
                                      definitelyAddedPages: added)
    }

    func goodnotesOCRStatus(for materialID: String) throws -> MaterialOCRStatus? {
        guard try !rows("SELECT material_id FROM goodnotes_versions WHERE material_id = ? LIMIT 1",
                        values: [materialID]).isEmpty else { return nil }
        let row = try rows("""
            SELECT SUM(CASE WHEN length(trim(p.text)) < 20 THEN 1 ELSE 0 END) AS candidates,
                   SUM(CASE WHEN o.page_id IS NOT NULL THEN 1 ELSE 0 END) AS processed,
                   SUM(CASE WHEN o.mean_confidence < 0.6 THEN 1 ELSE 0 END) AS low_confidence,
                   SUM(CASE WHEN r.page_id IS NOT NULL THEN 1 ELSE 0 END) AS approved
            FROM material_pages p LEFT JOIN material_page_ocr o ON o.page_id = p.id
            LEFT JOIN material_page_ocr_review r ON r.page_id = p.id
            WHERE p.material_id = ?
            """, values: [materialID]).first
        return MaterialOCRStatus(candidatePages: Int(row?["candidates"] ?? "0") ?? 0,
                                 processedPages: Int(row?["processed"] ?? "0") ?? 0,
                                 lowConfidencePages: Int(row?["low_confidence"] ?? "0") ?? 0,
                                 approvedPages: Int(row?["approved"] ?? "0") ?? 0)
    }

    func goodnotesOCRPages(for materialID: String) throws -> [MaterialOCRPage] {
        try rows("""
            SELECT p.id, p.page_number, o.text, o.mean_confidence,
                   r.corrected_text, r.approved_at
            FROM material_pages p JOIN material_page_ocr o ON o.page_id = p.id
            JOIN goodnotes_documents d ON d.current_material_id = p.material_id
            LEFT JOIN material_page_ocr_review r ON r.page_id = p.id
            WHERE p.material_id = ? ORDER BY p.page_number
            """, values: [materialID]).compactMap { row in
                guard let id = row["id"], let pageNumber = row["page_number"].flatMap(Int.init) else {
                    return nil
                }
                return MaterialOCRPage(id: id, pageNumber: pageNumber,
                                       rawText: row["text"] ?? "",
                                       meanConfidence: Double(row["mean_confidence"] ?? "0") ?? 0,
                                       correctedText: row["corrected_text"],
                                       approvedAt: row["approved_at"])
            }
    }

    func approveGoodnotesOCR(pageID: String, materialID: String, correctedText: String) throws {
        guard correctedText.count <= 100_000 else {
            throw DatabaseError.sqlite("OCR 검토 텍스트가 너무 깁니다")
        }
        guard try !rows("""
            SELECT p.id FROM material_pages p JOIN material_page_ocr o ON o.page_id = p.id
            JOIN goodnotes_documents d ON d.current_material_id = p.material_id
            WHERE p.id = ? AND p.material_id = ? LIMIT 1
            """, values: [pageID, materialID]).isEmpty else {
            throw DatabaseError.sqlite("현재 PDF의 OCR 페이지를 찾지 못했습니다")
        }
        try execute("""
            INSERT INTO material_page_ocr_review (page_id, corrected_text, approved_at)
            VALUES (?, ?, ?)
            ON CONFLICT(page_id) DO UPDATE SET
              corrected_text = excluded.corrected_text, approved_at = excluded.approved_at
            """, values: [pageID, correctedText,
                          ISO8601DateFormatter().string(from: Date())])
    }

    func notes() throws -> [KnowledgeNote] {
        try rows("SELECT id, title, body, updated_at FROM personal_notes ORDER BY updated_at DESC").map {
            KnowledgeNote(id: $0["id"] ?? "", title: $0["title"] ?? "",
                          body: $0["body"] ?? "", updatedAt: $0["updated_at"] ?? "")
        }
    }

    func saveNote(_ note: KnowledgeNote) throws {
        let now = ISO8601DateFormatter().string(from: Date())
        try execute("""
        INSERT INTO personal_notes (id, title, body, created_at, updated_at) VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET title = excluded.title, body = excluded.body, updated_at = excluded.updated_at
        """, values: [note.id, note.title, note.body, now, now])
    }

    func memo(for lectureID: String) throws -> String {
        try rows("SELECT body FROM lecture_memos WHERE lecture_id = ?", values: [lectureID])
            .first?["body"] ?? ""
    }

    func saveMemo(_ body: String, for lectureID: String) throws {
        guard try !rows("SELECT id FROM lectures WHERE id = ? LIMIT 1", values: [lectureID]).isEmpty else {
            throw DatabaseError.sqlite("메모를 저장할 강의를 찾을 수 없습니다")
        }
        try execute("""
        INSERT INTO lecture_memos (lecture_id, body, updated_at) VALUES (?, ?, ?)
        ON CONFLICT(lecture_id) DO UPDATE SET body = excluded.body, updated_at = excluded.updated_at
        """, values: [lectureID, body, ISO8601DateFormatter().string(from: Date())])
    }

    func importLocalPDF(from sourceURL: URL, courseID: String?, lectureID: String? = nil,
                        subjectName: String? = nil) throws -> MaterialItem {
        if let subjectName {
            guard courseID == nil, lectureID == nil,
                  GoodnotesClassifier.allowedSubjects.contains(subjectName) else {
                throw DatabaseError.sqlite("PDF를 추가할 과목 폴더가 올바르지 않습니다")
            }
        }
        guard sourceURL.isFileURL else { throw DatabaseError.sqlite("로컬 PDF 파일을 선택해 주세요") }
        let accessGranted = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessGranted { sourceURL.stopAccessingSecurityScopedResource() } }

        let source = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
        let resourceValues = try source.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
        guard resourceValues.isRegularFile == true else {
            throw DatabaseError.sqlite("일반 PDF 파일만 가져올 수 있습니다")
        }
        guard let preliminaryDocument = PDFDocument(url: source), preliminaryDocument.pageCount > 0,
              !preliminaryDocument.isEncrypted else {
            throw DatabaseError.sqlite("PDF를 읽을 수 없거나 암호로 보호되어 있습니다")
        }
        let lecture = try lectureID.flatMap {
            try rows("SELECT id, course_id FROM lectures WHERE id = ? LIMIT 1", values: [$0]).first
        }
        if lectureID != nil && lecture == nil {
            throw DatabaseError.sqlite("자료를 연결할 강의를 찾을 수 없습니다")
        }
        let selectedCourseID = courseID ?? lecture?["course_id"]
        if let selectedCourseID,
           try rows("SELECT id FROM courses WHERE id = ? LIMIT 1", values: [selectedCourseID]).isEmpty {
            throw DatabaseError.sqlite("자료를 연결할 과목을 찾을 수 없습니다")
        }

        let contentHash = try Self.sha256(of: source)
        let provider = "ravil_local_pdf"
        let externalID = source.path
        let materialDirectory = location.deletingLastPathComponent()
            .appendingPathComponent("Materials", isDirectory: true)
        try FileManager.default.createDirectory(at: materialDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o700)],
                                              ofItemAtPath: materialDirectory.path)
        let stored = materialDirectory.appendingPathComponent("\(contentHash).pdf")
        if FileManager.default.fileExists(atPath: stored.path) {
            guard try Self.sha256(of: stored) == contentHash else {
                throw DatabaseError.sqlite("저장된 PDF의 내용이 예상한 해시와 다릅니다")
            }
        } else {
            let temporary = materialDirectory.appendingPathComponent(".\(UUID().uuidString).pdf")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try FileManager.default.copyItem(at: source, to: temporary)
            guard try Self.sha256(of: temporary) == contentHash else {
                throw DatabaseError.sqlite("PDF를 복사하는 동안 내용이 변경되었습니다")
            }
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)],
                                                  ofItemAtPath: temporary.path)
            if !FileManager.default.fileExists(atPath: stored.path) {
                try FileManager.default.moveItem(at: temporary, to: stored)
            }
        }
        guard let document = PDFDocument(url: stored), document.pageCount > 0,
              !document.isEncrypted else {
            throw DatabaseError.sqlite("보관된 PDF를 읽을 수 없습니다")
        }
        let pageTexts = (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
        let hasTextLayer = pageTexts.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        try execute("BEGIN IMMEDIATE")
        do {
            var materialCourseID = selectedCourseID
            if let subjectName {
                if let existing = try rows("SELECT id FROM courses WHERE name = ? ORDER BY rowid LIMIT 1",
                                           values: [subjectName]).first?["id"] {
                    materialCourseID = existing
                } else {
                    let id = UUID().uuidString
                    try execute("INSERT INTO courses (id, semester_id, name) VALUES (?, NULL, ?)",
                                values: [id, subjectName])
                    materialCourseID = id
                }
            }
            if let existingID = try rows("""
                SELECT id FROM course_materials
                WHERE provider = ? AND external_id = ? AND content_hash = ?
                ORDER BY version DESC LIMIT 1
                """, values: [provider, externalID, contentHash]).first?["id"] {
                if let materialCourseID {
                    try execute("UPDATE course_materials SET course_id = ? WHERE id = ?",
                                values: [materialCourseID, existingID])
                }
                if let lectureID {
                    try execute("UPDATE course_materials SET lecture_id = ? WHERE id = ?",
                                values: [lectureID, existingID])
                }
                try execute("COMMIT")
                return try materialItem(for: existingID)
            }

            let previous = try rows("""
                SELECT MAX(version) AS version FROM course_materials
                WHERE provider = ? AND external_id = ?
                """, values: [provider, externalID]).first?["version"]
            let version = (previous.flatMap(Int.init) ?? 0) + 1
            let materialID = UUID().uuidString
            let now = ISO8601DateFormatter().string(from: Date())
            let modified = resourceValues.contentModificationDate.map { ISO8601DateFormatter().string(from: $0) }
            try execute("""
                INSERT INTO course_materials
                  (id, course_id, lecture_id, provider, external_id, external_url,
                   file_name, mime_type, local_path, content_hash, source_modified_at,
                   version, page_count, has_text_layer, status, ingested_at)
                VALUES (?, ?, ?, ?, ?, NULL, ?, 'application/pdf', ?, ?, ?, ?, ?, ?, 'ingested', ?)
                """, values: [materialID, materialCourseID, lectureID, provider, externalID,
                              source.lastPathComponent, stored.path, contentHash, modified,
                              String(version), String(pageTexts.count), hasTextLayer ? "1" : "0", now])
            for (index, pageText) in pageTexts.enumerated() {
                let textHash = SHA256.hash(data: Data(pageText.utf8))
                    .map { String(format: "%02x", $0) }.joined()
                try execute("""
                    INSERT INTO material_pages (id, material_id, page_number, text, text_hash)
                    VALUES (?, ?, ?, ?, ?)
                    """, values: [UUID().uuidString, materialID, String(index + 1), pageText, textHash])
            }
            try execute("COMMIT")
            return try materialItem(for: materialID)
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func materialItem(for id: String) throws -> MaterialItem {
        guard let row = try rows("""
            SELECT m.id, m.lecture_id, m.course_id, m.file_name, m.status, m.page_count, m.local_path, m.external_url,
                   COALESCE(g.subject, c.name, '') AS course, g.document_kind,
                   gc.teacher_name, gc.needs_review
            FROM course_materials m
            LEFT JOIN courses c ON c.id = m.course_id
            LEFT JOIN goodnotes_documents g ON g.current_material_id = m.id
            LEFT JOIN goodnotes_classifications gc ON gc.document_id = g.id
            WHERE m.id = ? LIMIT 1
            """, values: [id]).first else {
            throw DatabaseError.sqlite("저장된 강의자료를 찾을 수 없습니다")
        }
        return MaterialItem(id: row["id"] ?? "", lectureID: row["lecture_id"], courseID: row["course_id"],
                            title: row["file_name"] ?? "",
                            course: row["course"] ?? "", status: row["status"] ?? "",
                            pageCount: row["page_count"].flatMap(Int.init),
                            localPath: row["local_path"], externalURL: row["external_url"],
                            documentKind: row["document_kind"], teacherName: row["teacher_name"],
                            classificationNeedsReview: row["needs_review"] == "1")
    }

    private static func sha256(of url: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hasher = SHA256()
        while true {
            let chunk = try input.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func search(_ term: String) throws -> [SearchHit] {
        let match = "%\(term)%"
        var hits: [SearchHit] = []
        for row in try rows("SELECT id, title, lecture_date FROM lectures WHERE title LIKE ? LIMIT 20", values: [match]) {
            hits.append(SearchHit(id: "lecture-\(row["id"] ?? "")", kind: .lecture,
                                  title: row["title"] ?? "", excerpt: row["lecture_date"] ?? "",
                                  targetID: row["id"] ?? "", startMilliseconds: nil))
        }
        for row in try rows("""
        SELECT s.id, s.lecture_id, s.text, s.start_ms, l.title
        FROM transcript_segments s JOIN lectures l ON l.id = s.lecture_id
        WHERE s.text LIKE ? AND NOT EXISTS (
            SELECT 1 FROM transcript_superseded_segments old WHERE old.segment_id = s.id
        ) ORDER BY l.lecture_date DESC LIMIT 30
        """, values: [match]) {
            hits.append(SearchHit(id: "transcript-\(row["id"] ?? "")", kind: .transcript,
                                  title: row["title"] ?? "", excerpt: row["text"] ?? "",
                                  targetID: row["lecture_id"] ?? "",
                                  startMilliseconds: Int(row["start_ms"] ?? "")))
        }
        for row in try rows("""
            SELECT m.id, m.file_name FROM course_materials m
            WHERE m.file_name LIKE ? AND (m.provider <> 'goodnotes_drive_pdf' OR EXISTS (
                SELECT 1 FROM goodnotes_documents g WHERE g.current_material_id = m.id
            )) LIMIT 15
            """, values: [match]) {
            hits.append(SearchHit(id: "material-\(row["id"] ?? "")", kind: .material,
                                  title: row["file_name"] ?? "", excerpt: "강의자료",
                                  targetID: row["id"] ?? "", startMilliseconds: nil))
        }
        for row in try rows("""
            SELECT p.id, p.material_id, p.page_number, p.text, m.file_name
            FROM material_pages p JOIN course_materials m ON m.id = p.material_id
            WHERE p.text LIKE ? AND (m.provider <> 'goodnotes_drive_pdf' OR EXISTS (
                SELECT 1 FROM goodnotes_documents g WHERE g.current_material_id = m.id
            ))
            ORDER BY m.ingested_at DESC, p.page_number ASC LIMIT 30
            """, values: [match]) {
            let page = row["page_number"] ?? "?"
            let excerpt = Self.materialPageExcerpt(row["text"] ?? "", matching: term)
            hits.append(SearchHit(id: "material-page-\(row["id"] ?? "")", kind: .material,
                                  title: row["file_name"] ?? "", excerpt: "\(page)쪽 · \(excerpt)",
                                  targetID: row["material_id"] ?? "", startMilliseconds: nil,
                                  pageNumber: Int(page)))
        }
        for row in try rows("""
            SELECT o.page_id, p.material_id, p.page_number,
                   COALESCE(r.corrected_text, o.text) AS searchable_text,
                   r.page_id AS reviewed_page_id, m.file_name
            FROM material_page_ocr o JOIN material_pages p ON p.id = o.page_id
            JOIN course_materials m ON m.id = p.material_id
            JOIN goodnotes_documents g ON g.current_material_id = m.id
            LEFT JOIN material_page_ocr_review r ON r.page_id = o.page_id
            WHERE COALESCE(r.corrected_text, o.text) LIKE ?
            ORDER BY m.ingested_at DESC, p.page_number ASC LIMIT 20
            """, values: [match]) {
            let page = row["page_number"] ?? "?"
            let excerpt = Self.materialPageExcerpt(row["searchable_text"] ?? "", matching: term)
            let reviewLabel = row["reviewed_page_id"] == nil ? "OCR 미검토" : "OCR 검토됨"
            hits.append(SearchHit(id: "material-ocr-\(row["page_id"] ?? "")", kind: .material,
                                  title: row["file_name"] ?? "", excerpt: "\(page)쪽 · \(reviewLabel) · \(excerpt)",
                                  targetID: row["material_id"] ?? "", startMilliseconds: nil,
                                  pageNumber: Int(page)))
        }
        for row in try rows("SELECT id, title, body FROM personal_notes WHERE title LIKE ? OR body LIKE ? LIMIT 15", values: [match, match]) {
            hits.append(SearchHit(id: "note-\(row["id"] ?? "")", kind: .note,
                                  title: row["title"] ?? "", excerpt: String((row["body"] ?? "").prefix(130)),
                                  targetID: row["id"] ?? "", startMilliseconds: nil))
        }
        return hits
    }

    private static func materialPageExcerpt(_ text: String, matching term: String) -> String {
        let compact = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = compact.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return String(compact.prefix(130))
        }
        let start = compact.index(match.lowerBound, offsetBy: -45, limitedBy: compact.startIndex)
            ?? compact.startIndex
        let end = compact.index(match.upperBound, offsetBy: 80, limitedBy: compact.endIndex)
            ?? compact.endIndex
        return "\(start == compact.startIndex ? "" : "…")\(compact[start..<end])\(end == compact.endIndex ? "" : "…")"
    }

    func addRecording(title: String, courseID: String?, audioURL: URL, startedAt: Date,
                      provider: String = "ravil_recorder") throws -> String {
        let lectureID = UUID().uuidString
        let sourceID = UUID().uuidString
        let now = ISO8601DateFormatter().string(from: Date())
        let day = DateFormatter.localizedString(from: startedAt, dateStyle: .short, timeStyle: .none)
        let isoDay = Self.dayFormatter.string(from: startedAt)
        let bytes = try FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int ?? 0
        let mimeType = UTType(filenameExtension: audioURL.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("""
            INSERT INTO lectures (id, title, lecture_date, source_status, created_at, updated_at, started_at, course_id)
            VALUES (?, ?, ?, 'recorded', ?, ?, ?, ?)
            """, values: [lectureID, title.isEmpty ? day : title, isoDay, now, now,
                          ISO8601DateFormatter().string(from: startedAt), courseID])
            try execute("""
            INSERT INTO external_sources (id, lecture_id, provider, external_id, raw_payload_json, imported_at)
            VALUES (?, ?, ?, ?, '{}', ?)
            """, values: [sourceID, lectureID, provider, lectureID, now])
            try execute("""
            INSERT INTO audio_assets (id, lecture_id, external_source_id, provider_external_id, local_path, mime_type, size_bytes)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """, values: [UUID().uuidString, lectureID, sourceID, lectureID,
                          audioURL.path, mimeType, String(bytes)])
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
        return lectureID
    }

    func saveTranscript(_ phrases: [RecognizedPhrase], for lectureID: String,
                        options: TranscriptionOptions = .standard,
                        modelID: String = "unspecified") throws {
        guard !phrases.isEmpty,
              phrases.allSatisfy({ $0.offsets.from >= 0 && $0.offsets.to >= $0.offsets.from
                  && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw DatabaseError.sqlite("비어 있거나 시간이 올바르지 않은 전사는 저장하지 않습니다")
        }
        guard try !rows("""
            SELECT id FROM external_sources
            WHERE lecture_id = ? AND provider IN ('ravil_recorder', 'ravil_audio_import')
            ORDER BY imported_at DESC LIMIT 1
            """, values: [lectureID]).isEmpty else {
            throw DatabaseError.sqlite("이 녹음의 원본 연결을 찾을 수 없습니다")
        }
        let runSourceID = UUID().uuidString
        let now = ISO8601DateFormatter().string(from: Date())
        let payload = try JSONSerialization.data(withJSONObject: [
            "engine": "whisper-cpp", "modelID": modelID, "language": options.language,
            "translateToEnglish": options.translateToEnglish,
            "keywordPrompt": options.keywordPrompt,
            "useVAD": options.useVAD,
            "vadModelID": options.useVAD ? (AppPaths.bundledVADModel?.lastPathComponent ?? "") : ""
        ], options: [.sortedKeys])
        let payloadText = String(decoding: payload, as: UTF8.self)
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("""
                INSERT INTO external_sources (id, lecture_id, provider, external_id, raw_payload_json, imported_at)
                VALUES (?, ?, 'ravil_transcription', ?, ?, ?)
                """, values: [runSourceID, lectureID, runSourceID, payloadText, now])
            try execute("""
                INSERT INTO transcript_superseded_segments (segment_id, replacement_source_id, superseded_at)
                SELECT t.id, ?, ? FROM transcript_segments t
                JOIN external_sources s ON s.id = t.external_source_id
                WHERE t.lecture_id = ? AND s.provider IN
                  ('ravil_recorder', 'ravil_audio_import', 'ravil_transcription')
                  AND NOT EXISTS (SELECT 1 FROM transcript_superseded_segments old WHERE old.segment_id = t.id)
                """, values: [runSourceID, now, lectureID])
            for (index, phrase) in phrases.enumerated() {
                try execute("""
                INSERT INTO transcript_segments (id, lecture_id, external_source_id, provider_segment_id,
                  ordinal, start_ms, end_ms, text, speaker_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL)
                """, values: [UUID().uuidString, lectureID, runSourceID, "whisper-\(index)",
                              String(index), String(phrase.offsets.from), String(phrase.offsets.to),
                              phrase.text.trimmingCharacters(in: .whitespacesAndNewlines)])
            }
            try execute("UPDATE lectures SET source_status = 'ready', updated_at = ? WHERE id = ?",
                        values: [now, lectureID])
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
