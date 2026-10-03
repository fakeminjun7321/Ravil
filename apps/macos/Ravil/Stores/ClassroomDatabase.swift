import Foundation

extension LibraryDatabase {
    func createClassroomTables() throws {
        try execute("""
        CREATE TABLE IF NOT EXISTS lecture_bookmarks (
          id TEXT PRIMARY KEY, lecture_id TEXT NOT NULL REFERENCES lectures(id),
          milliseconds INTEGER NOT NULL CHECK(milliseconds >= 0), material_id TEXT,
          page INTEGER, note TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS bookmarks_lecture ON lecture_bookmarks(lecture_id, milliseconds);
        CREATE TABLE IF NOT EXISTS transcript_edits (
          id TEXT PRIMARY KEY, segment_id TEXT NOT NULL REFERENCES transcript_segments(id),
          old_text TEXT NOT NULL, new_text TEXT NOT NULL, old_speaker TEXT, new_speaker TEXT,
          created_at TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS brain_answers (id TEXT PRIMARY KEY, payload TEXT NOT NULL);
        """)
    }

    func bookmarks(for lectureID: String) throws -> [LectureBookmark] {
        try rows("SELECT * FROM lecture_bookmarks WHERE lecture_id = ? ORDER BY milliseconds", values: [lectureID]).map {
            LectureBookmark(id: $0["id"]!, lectureID: lectureID, milliseconds: Int($0["milliseconds"]!)!,
                            materialID: $0["material_id"], page: $0["page"].flatMap(Int.init), note: $0["note"] ?? "")
        }
    }

    func saveBookmark(_ b: LectureBookmark) throws {
        guard b.milliseconds >= 0, b.page == nil || b.page! > 0 else { throw DatabaseError.sqlite("북마크 위치가 올바르지 않습니다") }
        if let materialID = b.materialID {
            guard let row = try rows("SELECT page_count FROM course_materials WHERE id = ?", values: [materialID]).first,
                  b.page == nil || b.page! <= (Int(row["page_count"] ?? "0") ?? 0) else {
                throw DatabaseError.sqlite("PDF 판본 또는 페이지를 찾을 수 없습니다")
            }
        }
        try execute("""
        INSERT INTO lecture_bookmarks (id, lecture_id, milliseconds, material_id, page, note)
        VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET note = excluded.note
        """, values: [b.id, b.lectureID, String(b.milliseconds), b.materialID, b.page.map(String.init), b.note])
    }

    func editTranscript(segmentID: String, text: String, speaker: String?) throws {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let old = try rows("SELECT text, speaker_id FROM transcript_segments WHERE id = ?", values: [segmentID]).first else {
            throw DatabaseError.sqlite("수정할 전사와 내용을 확인해 주세요")
        }
        let name = speaker?.trimmingCharacters(in: .whitespacesAndNewlines)
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("INSERT INTO transcript_edits VALUES (?, ?, ?, ?, ?, ?, ?)", values: [UUID().uuidString, segmentID, old["text"], clean, old["speaker_id"], name, ISO8601DateFormatter().string(from: Date())])
            try execute("UPDATE transcript_segments SET text = ?, speaker_id = ? WHERE id = ?", values: [clean, name?.isEmpty == true ? nil : name, segmentID])
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    func renameSpeaker(lectureID: String, old: String, new: String) throws {
        let segments = try transcript(for: lectureID).filter { $0.speaker == old }
        for s in segments { try editTranscript(segmentID: s.id, text: s.text, speaker: new) }
    }

    func brainSources(query: String, lectureID: String? = nil) throws -> [BrainSource] {
        // Parameterized literal LIKE; deterministic, local retrieval with source locations.
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || lectureID != nil else { return [] }
        let words = Array(query.split(whereSeparator: { $0.isWhitespace }).prefix(8)).map(String.init)
        let tokens = words.isEmpty ? [""] : words
        func matches(_ text: String) -> Int {
            tokens.reduce(0) { $0 + (text.localizedCaseInsensitiveContains($1) ? 1 : 0) }
        }
        func excerpt(_ text: String) -> String {
            let compact = text.replacingOccurrences(of: "\r", with: "")
            guard let match = tokens.compactMap({ compact.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) }).first else { return String(compact.prefix(1600)) }
            let start = compact.index(match.lowerBound, offsetBy: -500, limitedBy: compact.startIndex) ?? compact.startIndex
            return (start == compact.startIndex ? "" : "…") + String(compact[start...].prefix(1599))
        }
        var sources: [BrainSource] = []
        for row in try rows("""
          SELECT s.id, s.lecture_id, s.text, s.start_ms, l.title FROM transcript_segments s
          JOIN lectures l ON l.id = s.lecture_id
          WHERE (? IS NULL OR s.lecture_id = ?) AND NOT EXISTS
          (SELECT 1 FROM transcript_superseded_segments old WHERE old.segment_id = s.id)
          ORDER BY l.lecture_date DESC, s.ordinal LIMIT 30000
          """, values: [lectureID, lectureID]) {
            let text = row["text"] ?? ""
            if matches(text + (row["title"] ?? "")) > 0 || (query.isEmpty && lectureID != nil) {
                sources.append(BrainSource(id: "transcript-" + row["id"]!, kind: "transcript", targetID: row["lecture_id"]!, title: row["title"]!, text: excerpt(text), milliseconds: Int(row["start_ms"]!), page: nil))
            }
        }
        for row in try rows("""
          SELECT p.id, p.material_id, p.page_number, m.file_name,
          COALESCE(r.corrected_text, NULLIF(p.text, ''), o.text, '') AS content
          FROM material_pages p JOIN course_materials m ON m.id = p.material_id
          LEFT JOIN material_page_ocr o ON o.page_id = p.id
          LEFT JOIN material_page_ocr_review r ON r.page_id = p.id
          WHERE (? IS NULL OR m.lecture_id = ?) AND
          (m.provider <> 'goodnotes_drive_pdf' OR EXISTS (SELECT 1 FROM goodnotes_documents g WHERE g.current_material_id = m.id))
          ORDER BY m.ingested_at DESC, p.page_number LIMIT 12000
          """, values: [lectureID, lectureID]) {
            let text = row["content"] ?? ""
            if !text.isEmpty && (matches(text + (row["file_name"] ?? "")) > 0 || (query.isEmpty && lectureID != nil)) {
                sources.append(BrainSource(id: "page-" + row["id"]!, kind: "material", targetID: row["material_id"]!, title: row["file_name"]!, text: excerpt(text), milliseconds: nil, page: Int(row["page_number"]!)))
            }
        }
        for row in try rows("SELECT l.id, l.title, m.body FROM lecture_memos m JOIN lectures l ON l.id = m.lecture_id WHERE (? IS NULL OR l.id = ?)", values: [lectureID, lectureID]) {
            if matches((row["body"] ?? "") + (row["title"] ?? "")) > 0 || (query.isEmpty && lectureID != nil) {
                sources.append(BrainSource(id: "memo-" + row["id"]!, kind: "lecture", targetID: row["id"]!, title: row["title"]! + " · 내 노트", text: excerpt(row["body"] ?? ""), milliseconds: nil, page: nil))
            }
        }
        if lectureID == nil {
            for note in try notes() where matches(note.title + note.body) > 0 {
                sources.append(BrainSource(id: "note-" + note.id, kind: "note", targetID: note.id, title: note.title, text: excerpt(note.body), milliseconds: nil, page: nil))
            }
        }
        return Array(sources.sorted {
            let a = matches($0.text + $0.title), b = matches($1.text + $1.title)
            return a == b ? $0.id < $1.id : a > b
        }.prefix(40))
    }

    func saveBrainAnswer(_ answer: BrainAnswer) throws {
        let payload = String(decoding: try JSONEncoder().encode(answer), as: UTF8.self)
        try execute("INSERT OR REPLACE INTO brain_answers VALUES (?, ?)", values: [answer.id, payload])
    }
    func brainAnswers() throws -> [BrainAnswer] {
        try rows("SELECT payload FROM brain_answers").compactMap {
            try JSONDecoder().decode(BrainAnswer.self, from: Data(($0["payload"] ?? "").utf8))
        }.sorted { $0.createdAt > $1.createdAt }
    }
}
