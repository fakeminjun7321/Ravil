import Foundation

extension LibraryDatabase {
    func examScopes() throws -> [ExamScopeItem] {
        try rows("""
            SELECT s.id, s.title, s.exam_date,
                   (SELECT COUNT(*) FROM exam_scope_materials sm WHERE sm.scope_id = s.id) AS material_count,
                   (SELECT COUNT(*) FROM quiz_cards c WHERE c.scope_id = s.id) AS card_count
            FROM exam_scopes s ORDER BY s.created_at DESC, s.id
            """).map { row in
                ExamScopeItem(id: row["id"] ?? "", title: row["title"] ?? "",
                              examDate: row["exam_date"],
                              materialCount: Int(row["material_count"] ?? "0") ?? 0,
                              cardCount: Int(row["card_count"] ?? "0") ?? 0)
            }
    }

    func createExamScope(title: String, examDate: String?,
                         ranges: [(materialID: String, startPage: Int, endPage: Int)]) throws -> String {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty, cleanTitle.count <= 100 else {
            throw DatabaseError.sqlite("시험 범위 이름을 1~100자로 입력해 주세요")
        }
        guard !ranges.isEmpty else { throw DatabaseError.sqlite("시험 범위에 자료를 하나 이상 선택해 주세요") }
        guard Set(ranges.map(\.materialID)).count == ranges.count else {
            throw DatabaseError.sqlite("시험 범위에 같은 자료가 중복됐습니다")
        }
        if let examDate, !examDate.isEmpty {
            guard examDate.range(of: "^\\d{4}-\\d{2}-\\d{2}$", options: .regularExpression) != nil else {
                throw DatabaseError.sqlite("시험 날짜는 YYYY-MM-DD 형식이어야 합니다")
            }
        }
        for range in ranges {
            guard let row = try rows("""
                SELECT m.page_count, m.provider, g.id AS current_document
                FROM course_materials m LEFT JOIN goodnotes_documents g ON g.current_material_id = m.id
                WHERE m.id = ? LIMIT 1
                """, values: [range.materialID]).first,
                  let pages = row["page_count"].flatMap(Int.init),
                  range.startPage >= 1, range.endPage >= range.startPage,
                  range.endPage <= pages,
                  row["provider"] != "goodnotes_drive_pdf" || row["current_document"] != nil else {
                throw DatabaseError.sqlite("시험 범위 페이지나 자료 판본을 확인해 주세요")
            }
        }
        let id = UUID().uuidString
        let now = ISO8601DateFormatter().string(from: Date())
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("INSERT INTO exam_scopes (id, title, exam_date, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
                        values: [id, cleanTitle, examDate?.isEmpty == true ? nil : examDate, now, now])
            for range in ranges {
                try execute("""
                    INSERT INTO exam_scope_materials (scope_id, material_id, start_page, end_page)
                    VALUES (?, ?, ?, ?)
                    """, values: [id, range.materialID, String(range.startPage), String(range.endPage)])
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
        return id
    }

    func examMaterials(scopeID: String) throws -> [ExamMaterialRange] {
        try rows("""
            SELECT sm.material_id, sm.start_page, sm.end_page,
                   m.file_name, m.page_count, m.provider,
                   COALESCE(g.subject, c.name, '') AS subject,
                   g.id AS current_document,
                   replacement.id AS replacement_material_id,
                   replacement.page_count AS replacement_page_count,
                   replacement.local_path AS replacement_local_path
            FROM exam_scope_materials sm
            JOIN course_materials m ON m.id = sm.material_id
            LEFT JOIN goodnotes_documents g ON g.current_material_id = m.id
            LEFT JOIN goodnotes_versions history ON history.material_id = m.id
            LEFT JOIN goodnotes_documents history_doc ON history_doc.id = history.document_id
            LEFT JOIN course_materials replacement ON replacement.id = history_doc.current_material_id
                AND replacement.id != m.id
            LEFT JOIN courses c ON c.id = m.course_id
            WHERE sm.scope_id = ? ORDER BY subject, m.file_name
            """, values: [scopeID]).compactMap { row in
                guard let id = row["material_id"],
                      let start = row["start_page"].flatMap(Int.init),
                      let end = row["end_page"].flatMap(Int.init) else { return nil }
                return ExamMaterialRange(materialID: id, title: row["file_name"] ?? "",
                                         subject: row["subject"] ?? "", startPage: start,
                                         endPage: end,
                                         pageCount: Int(row["page_count"] ?? "0") ?? 0,
                                         sourceIsCurrent: row["provider"] != "goodnotes_drive_pdf"
                                             || row["current_document"] != nil,
                                         replacementMaterialID: row["replacement_material_id"],
                                         replacementPageCount: row["replacement_page_count"].flatMap(Int.init),
                                         replacementLocalPath: row["replacement_local_path"])
            }
    }

    func rebaseExamScopeMaterial(scopeID: String, oldMaterialID: String,
                                 newMaterialID: String, startPage: Int, endPage: Int) throws {
        guard let candidate = try examMaterials(scopeID: scopeID).first(where: { $0.materialID == oldMaterialID }),
              !candidate.sourceIsCurrent,
              candidate.replacementMaterialID == newMaterialID,
              let pages = candidate.replacementPageCount,
              startPage >= 1, endPage >= startPage, endPage <= pages else {
            throw DatabaseError.sqlite("최신 PDF와 새 시험 범위 페이지를 확인해 주세요")
        }
        try execute("""
            UPDATE exam_scope_materials SET material_id = ?, start_page = ?, end_page = ?
            WHERE scope_id = ? AND material_id = ?
            """, values: [newMaterialID, String(startPage), String(endPage), scopeID, oldMaterialID])
    }

    func addQuizCard(scopeID: String, materialID: String, page: Int,
                     question: String, answer: String) throws -> String {
        let cleanQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanAnswer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanQuestion.isEmpty, !cleanAnswer.isEmpty,
              cleanQuestion.count <= 2_000, cleanAnswer.count <= 4_000 else {
            throw DatabaseError.sqlite("문제와 답을 입력해 주세요. 너무 긴 내용은 나눠 저장해 주세요")
        }
        guard let range = try examMaterials(scopeID: scopeID).first(where: { $0.materialID == materialID }),
              range.sourceIsCurrent, page >= range.startPage, page <= range.endPage else {
            throw DatabaseError.sqlite("현재 시험 범위에 포함된 최신 PDF 페이지를 선택해 주세요")
        }
        let id = UUID().uuidString
        try execute("""
            INSERT INTO quiz_cards
              (id, scope_id, question, answer, source_material_id, source_page, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """, values: [id, scopeID, cleanQuestion, cleanAnswer, materialID,
                          String(page), ISO8601DateFormatter().string(from: Date())])
        return id
    }

    func quizCards(scopeID: String) throws -> [QuizCardItem] {
        try rows("""
            SELECT q.id, q.scope_id, q.question, q.answer, q.source_material_id,
                   q.source_page, m.file_name, m.local_path, m.version, m.provider,
                   g.id AS current_document,
                   (SELECT COUNT(*) FROM quiz_reviews r WHERE r.card_id = q.id) AS review_count,
                   (SELECT COUNT(*) FROM quiz_reviews r WHERE r.card_id = q.id AND r.grade = 'wrong') AS wrong_count,
                   (SELECT r.grade FROM quiz_reviews r WHERE r.card_id = q.id
                    ORDER BY r.reviewed_at DESC, r.id DESC LIMIT 1) AS last_grade
            FROM quiz_cards q JOIN course_materials m ON m.id = q.source_material_id
            LEFT JOIN goodnotes_documents g ON g.current_material_id = m.id
            WHERE q.scope_id = ? ORDER BY q.created_at, q.id
            """, values: [scopeID]).compactMap { row in
                guard let id = row["id"], let materialID = row["source_material_id"],
                      let page = row["source_page"].flatMap(Int.init) else { return nil }
                return QuizCardItem(id: id, scopeID: row["scope_id"] ?? scopeID,
                                    question: row["question"] ?? "", answer: row["answer"] ?? "",
                                    materialID: materialID, materialTitle: row["file_name"] ?? "",
                                    materialPath: row["local_path"], sourcePage: page,
                                    sourceVersion: Int(row["version"] ?? "1") ?? 1,
                                    sourceIsCurrent: row["provider"] != "goodnotes_drive_pdf"
                                        || row["current_document"] != nil,
                                    reviewCount: Int(row["review_count"] ?? "0") ?? 0,
                                    wrongCount: Int(row["wrong_count"] ?? "0") ?? 0,
                                    lastGrade: row["last_grade"])
            }
    }

    func nextQuizCard(scopeID: String, excluding seenIDs: Set<String>) throws -> QuizCardItem? {
        let available = try quizCards(scopeID: scopeID).filter { $0.sourceIsCurrent && !seenIDs.contains($0.id) }
        if let unseen = available.first(where: { $0.reviewCount == 0 }) { return unseen }
        return available.filter { $0.lastGrade == "wrong" || $0.lastGrade == "unsure" }
            .sorted { lhs, rhs in
                if lhs.wrongCount != rhs.wrongCount { return lhs.wrongCount > rhs.wrongCount }
                return lhs.id < rhs.id
            }.first
    }

    func recordQuizReview(cardID: String, grade: QuizGrade) throws {
        guard let scopeID = try rows("SELECT scope_id FROM quiz_cards WHERE id = ? LIMIT 1",
                                     values: [cardID]).first?["scope_id"],
              try quizCards(scopeID: scopeID).contains(where: { $0.id == cardID && $0.sourceIsCurrent }) else {
            throw DatabaseError.sqlite("최신 자료에 연결된 복습 카드만 평가할 수 있습니다")
        }
        let value: String
        switch grade {
        case .wrong: value = "wrong"
        case .unsure: value = "unsure"
        case .correct: value = "correct"
        }
        try execute("INSERT INTO quiz_reviews (id, card_id, grade, reviewed_at) VALUES (?, ?, ?, ?)",
                    values: [UUID().uuidString, cardID, value,
                             ISO8601DateFormatter().string(from: Date())])
    }
}
