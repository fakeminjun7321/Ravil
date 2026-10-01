import Foundation

extension LibraryDatabase {
    /// Refresh classification metadata from already stored evidence. PDF bytes,
    /// source observations and version identities are deliberately left untouched.
    @discardableResult
    func reclassifyGoodnotesMaterials() throws -> Int {
        try execute("BEGIN IMMEDIATE")
        do {
            let documents = try rows("""
                SELECT d.id, d.relative_path, d.subject, d.document_kind,
                       m.page_count, p.text AS first_page_text, r.corrected_text,
                       c.subject_source, c.kind_source, c.teacher_name,
                       c.confidence, c.needs_review
                FROM goodnotes_documents d
                JOIN course_materials m ON m.id = d.current_material_id
                LEFT JOIN material_pages p ON p.id = (
                    SELECT id FROM material_pages
                    WHERE material_id = d.current_material_id AND page_number = 1
                    ORDER BY rowid LIMIT 1
                )
                LEFT JOIN material_page_ocr_review r ON r.page_id = p.id
                LEFT JOIN goodnotes_classifications c ON c.document_id = d.id
                WHERE m.provider = 'goodnotes_drive_pdf'
                """)
            let now = ISO8601DateFormatter().string(from: Date())
            var changed = 0
            for document in documents {
                guard let documentID = document["id"], let path = document["relative_path"] else { continue }
                let previousSubject = document["subject"] ?? GoodnotesClassifier.unclassifiedSubject
                let previousKind = document["document_kind"] ?? GoodnotesClassifier.unclassifiedKind
                let previousSubjectSource = document["subject_source"] ?? "provided"
                let previousKindSource = document["kind_source"] ?? "provided"
                let keepSubject = GoodnotesClassifier.allowedSubjects.contains(previousSubject)
                    && ["manual", "provided"].contains(previousSubjectSource)
                let keepKind = Self.validGoodnotesKind(previousKind)
                    && ["manual", "provided"].contains(previousKindSource)
                let text = document["first_page_text"] ?? ""
                let firstPageText = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? document["corrected_text"] ?? "" : text
                let result = try GoodnotesClassifier.classify(
                    relativePath: path, firstPageText: firstPageText,
                    pageCount: document["page_count"].flatMap(Int.init) ?? 0,
                    suppliedSubject: keepSubject ? previousSubject : nil,
                    suppliedKind: keepKind ? previousKind : nil)
                // Missing evidence must not erase a previously resolved automatic
                // classification, either. Explicit user choices always win.
                let subject = result.subject == GoodnotesClassifier.unclassifiedSubject
                    && GoodnotesClassifier.allowedSubjects.contains(previousSubject)
                    ? previousSubject : result.subject
                let kind = result.documentKind == GoodnotesClassifier.unclassifiedKind
                    && Self.validGoodnotesKind(previousKind) ? previousKind : result.documentKind
                let subjectSource = keepSubject || subject != result.subject
                    ? previousSubjectSource : result.subjectSource
                let kindSource = keepKind || kind != result.documentKind
                    ? previousKindSource : result.kindSource
                let hasManualChoice = (keepSubject && previousSubjectSource == "manual")
                    || (keepKind && previousKindSource == "manual")
                let confidence = hasManualChoice || subject != result.subject
                    ? document["confidence"].flatMap(Double.init) ?? result.confidence : result.confidence
                var providedSubjectConflict = false
                if keepSubject && previousSubjectSource == "provided" {
                    let automatic = try GoodnotesClassifier.classify(
                        relativePath: path, firstPageText: firstPageText,
                        pageCount: document["page_count"].flatMap(Int.init) ?? 0,
                        suppliedSubject: nil, suppliedKind: nil)
                    providedSubjectConflict = automatic.subject != GoodnotesClassifier.unclassifiedSubject
                        && automatic.subject != previousSubject
                }
                let protectedReview = keepSubject && keepKind && document["needs_review"] == "1"
                let needsReview = subject == GoodnotesClassifier.unclassifiedSubject
                    || kind == GoodnotesClassifier.unclassifiedKind
                    || subjectSource == "first_page"
                    || protectedReview || providedSubjectConflict
                    || (result.needsReview && !hasManualChoice)
                let reviewValue = needsReview ? "1" : "0"
                guard subject != previousSubject || kind != previousKind
                    || subjectSource != document["subject_source"]
                    || kindSource != document["kind_source"]
                    || confidence != document["confidence"].flatMap(Double.init)
                    || reviewValue != document["needs_review"] else { continue }
                try execute("""
                    UPDATE goodnotes_documents
                    SET subject = ?, document_kind = ?, updated_at = ? WHERE id = ?
                    """, values: [subject, kind, now, documentID])
                // Teacher is not inferred during a metadata backfill. This also
                // preserves an intentional manual clearing of the teacher field.
                try execute("""
                    INSERT INTO goodnotes_classifications
                      (document_id, subject_source, kind_source, teacher_name,
                       confidence, needs_review, classified_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(document_id) DO UPDATE SET
                      subject_source = excluded.subject_source,
                      kind_source = excluded.kind_source,
                      confidence = excluded.confidence,
                      needs_review = excluded.needs_review,
                      classified_at = excluded.classified_at
                    """, values: [documentID, subjectSource, kindSource, document["teacher_name"],
                                  String(confidence), reviewValue, now])
                changed += 1
            }
            try execute("COMMIT")
            return changed
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    static func validGoodnotesKind(_ value: String) -> Bool {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !clean.isEmpty && clean.count <= 80
            && clean != GoodnotesClassifier.unclassifiedKind
            && clean.rangeOfCharacter(from: .controlCharacters) == nil
    }

    func updateGoodnotesClassification(materialID: String, subject: String,
                                       documentKind: String, teacherName: String?) throws {
        let cleanKind = documentKind.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTeacher = teacherName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard GoodnotesClassifier.allowedSubjects.contains(subject),
              !cleanKind.isEmpty, cleanKind.count <= 80,
              cleanKind != GoodnotesClassifier.unclassifiedKind,
              cleanKind.rangeOfCharacter(from: .controlCharacters) == nil,
              cleanTeacher.count <= 80,
              cleanTeacher.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw DatabaseError.sqlite("과목과 자료 종류를 확인해 주세요")
        }
        guard let documentID = try rows("""
            SELECT id FROM goodnotes_documents WHERE current_material_id = ? LIMIT 1
            """, values: [materialID]).first?["id"] else {
            throw DatabaseError.sqlite("현재 Goodnotes PDF를 찾지 못했습니다")
        }
        let now = ISO8601DateFormatter().string(from: Date())
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("""
                UPDATE goodnotes_documents
                SET subject = ?, document_kind = ?, updated_at = ? WHERE id = ?
                """, values: [subject, cleanKind, now, documentID])
            try execute("""
                INSERT INTO goodnotes_classifications
                  (document_id, subject_source, kind_source, teacher_name,
                   confidence, needs_review, classified_at)
                VALUES (?, 'manual', 'manual', ?, '1', '0', ?)
                ON CONFLICT(document_id) DO UPDATE SET
                  subject_source = 'manual', kind_source = 'manual',
                  teacher_name = excluded.teacher_name, confidence = '1',
                  needs_review = '0', classified_at = excluded.classified_at
                """, values: [documentID, cleanTeacher.isEmpty ? nil : cleanTeacher, now])
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
}
