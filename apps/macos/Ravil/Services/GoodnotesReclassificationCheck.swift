import AppKit
import Foundation

enum GoodnotesReclassificationCheck {
    static func run() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RavilReclassificationCheck-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LibraryDatabase(location: directory.appendingPathComponent("test.sqlite"),
                                            importLegacy: false)

        func seed(_ id: String, path: String, text: String = "", subject: String = GoodnotesClassifier.unclassifiedSubject,
                  kind: String = GoodnotesClassifier.unclassifiedKind,
                  subjectSource: String? = "review", kindSource: String = "review",
                  teacher: String? = nil, confidence: String = "0", needsReview: String = "1") throws {
            // There is intentionally no PDF at local_path. Backfill must only read
            // the text already stored in SQLite and must never reopen PDF bytes.
            try database.execute("""
                INSERT INTO course_materials
                  (id, provider, external_id, file_name, mime_type, local_path,
                   content_hash, version, page_count, has_text_layer, status, ingested_at)
                VALUES (?, 'goodnotes_drive_pdf', ?, ?, 'application/pdf', ?, ?, 1, 2, 1, 'ingested', 'before')
                """, values: [id, "drive-\(id)", (path as NSString).lastPathComponent,
                              directory.appendingPathComponent("absent-\(id).pdf").path, "hash-\(id)"])
            try database.execute("""
                INSERT INTO material_pages (id, material_id, page_number, text, text_hash)
                VALUES (?, ?, 1, ?, ?)
                """, values: ["page-\(id)", id, text, "text-\(id)"])
            try database.execute("""
                INSERT INTO goodnotes_documents
                  (id, midterm_root_folder_id, relative_path, path_key, subject, document_kind,
                   current_material_id, created_at, updated_at)
                VALUES (?, 'root', ?, ?, ?, ?, ?, 'before', 'before')
                """, values: ["doc-\(id)", path, path.lowercased(), subject, kind, id])
            if let subjectSource {
                try database.execute("""
                    INSERT INTO goodnotes_classifications
                      (document_id, subject_source, kind_source, teacher_name, confidence, needs_review, classified_at)
                    VALUES (?, ?, ?, ?, ?, ?, 'before')
                    """, values: ["doc-\(id)", subjectSource, kindSource, teacher, confidence, needsReview])
            }
            try database.execute("""
                INSERT INTO goodnotes_versions (material_id, document_id, version, content_hash)
                VALUES (?, ?, 1, ?)
                """, values: [id, "doc-\(id)", "hash-\(id)"])
            try database.execute("""
                INSERT INTO goodnotes_source_observations
                  (observation_key, document_id, material_id, midterm_root_folder_id,
                   drive_file_id, revision_id, relative_path, source_url, observed_at)
                VALUES (?, ?, ?, 'root', ?, 'revision-1', ?, ?, 'before')
                """, values: ["observation-\(id)", "doc-\(id)", id, "drive-\(id)", path,
                              "https://drive.google.com/file/d/drive-\(id)/view"])
        }
        func classification(_ id: String) throws -> [String: String] {
            try database.rows("""
                SELECT d.subject, d.document_kind, c.subject_source, c.kind_source,
                       c.teacher_name, c.confidence, c.needs_review
                FROM goodnotes_documents d LEFT JOIN goodnotes_classifications c ON c.document_id = d.id
                WHERE d.id = ?
                """, values: ["doc-\(id)"]).first ?? [:]
        }
        func addOCR(_ id: String, approved: String?) throws {
            try database.execute("""
                INSERT INTO material_page_ocr
                  (page_id, text, mean_confidence, status, engine_version, processed_at)
                VALUES (?, 'Modern physics', 0.9, 'complete', 'test', 'before')
                """, values: ["page-\(id)"])
            if let approved {
                try database.execute("""
                    INSERT INTO material_page_ocr_review (page_id, corrected_text, approved_at)
                    VALUES (?, ?, 'before')
                    """, values: ["page-\(id)", approved])
            }
        }

        try seed("nested", path: "Goodnotes/2026/현대물리/중간고사/김수정T_학습지.pdf",
                 subject: "미분류", subjectSource: nil)
        try seed("legacy", path: "Archive/General Physics/학습지.pdf", subject: "미분류",
                 subjectSource: "provided", kindSource: "provided")
        try seed("manual", path: "English/원본교사T_학습지.pdf", subject: "물실", kind: "실험 보고서",
                 subjectSource: "manual", kindSource: "manual", teacher: "직접 입력", confidence: "0.91",
                 needsReview: "0")
        try seed("provided", path: "English/학습지.pdf", subject: "천문", kind: "교재",
                 subjectSource: "provided", kindSource: "provided", confidence: "1", needsReview: "1")
        try seed("provided-blank", path: "Astronomy/공백.pdf", subject: "천문", kind: "자료",
                 subjectSource: "provided", kindSource: "provided", confidence: "1", needsReview: "1")
        try seed("approved", path: "Archive/검토자료.pdf", kind: "자료", kindSource: "provided")
        try addOCR("approved", approved: "Modern physics")
        try seed("unapproved", path: "Archive/미검토자료.pdf", kind: "자료", kindSource: "provided")
        try addOCR("unapproved", approved: nil)
        try seed("native", path: "Archive/원문자료.pdf", text: "Astronomy", kind: "자료", kindSource: "provided")
        try addOCR("native", approved: "Modern physics")
        try seed("history", path: "Archive/판본자료.pdf", text: "English", kind: "자료", kindSource: "provided")
        try database.execute("""
            INSERT INTO course_materials
              (id, provider, external_id, file_name, mime_type, content_hash, version,
               page_count, has_text_layer, status, ingested_at)
            VALUES ('current-history', 'goodnotes_drive_pdf', 'drive-history', '판본자료.pdf',
                    'application/pdf', 'current-hash', 2, 2, 1, 'ingested', 'before')
            """)
        try database.execute("""
            INSERT INTO material_pages (id, material_id, page_number, text, text_hash)
            VALUES ('current-page', 'current-history', 1, 'Astronomy', 'current-text')
            """)
        try database.execute("""
            INSERT INTO goodnotes_versions (material_id, document_id, version, content_hash)
            VALUES ('current-history', 'doc-history', 2, 'current-hash')
            """)
        try database.execute("UPDATE goodnotes_documents SET current_material_id = 'current-history' WHERE id = 'doc-history'")
        let versionsBefore = try database.rows("SELECT * FROM goodnotes_versions ORDER BY material_id")
        let observationsBefore = try database.rows("SELECT * FROM goodnotes_source_observations ORDER BY observation_key")
        let materialsBefore = try database.rows("SELECT * FROM course_materials ORDER BY id")
        let manualBefore = try classification("manual")
        let providedBefore = try classification("provided")
        let blankBefore = try classification("provided-blank")
        let changed = try database.reclassifyGoodnotesMaterials()
        let nested = try classification("nested")
        guard changed == 5, nested["subject"] == "현물", nested["document_kind"] == "학습지",
              nested["subject_source"] == "folder", nested["teacher_name"] == nil,
              try classification("legacy")["subject"] == "일물",
              try classification("manual") == manualBefore,
              try classification("provided") == providedBefore,
              try classification("provided-blank") == blankBefore,
              try classification("approved")["subject"] == "현물",
              try classification("approved")["subject_source"] == "first_page",
              try classification("unapproved")["subject"] == GoodnotesClassifier.unclassifiedSubject,
              try classification("native")["subject"] == "천문",
              try classification("history")["subject"] == "천문" else {
            throw DatabaseError.sqlite("저장 자료 재분류·수동/제공 분류·검토 OCR 우선순위 검사가 실패했습니다")
        }
        let documentsAfter = try database.rows("SELECT * FROM goodnotes_documents ORDER BY id")
        let classificationsAfter = try database.rows("SELECT * FROM goodnotes_classifications ORDER BY document_id")
        guard try database.reclassifyGoodnotesMaterials() == 0,
              try database.rows("SELECT * FROM goodnotes_documents ORDER BY id") == documentsAfter,
              try database.rows("SELECT * FROM goodnotes_classifications ORDER BY document_id") == classificationsAfter,
              try database.rows("SELECT * FROM goodnotes_versions ORDER BY material_id") == versionsBefore,
              try database.rows("SELECT * FROM goodnotes_source_observations ORDER BY observation_key") == observationsBefore,
              try database.rows("SELECT * FROM course_materials ORDER BY id") == materialsBefore else {
            throw DatabaseError.sqlite("재분류의 반복 실행 또는 PDF·판본·출처 보존 검사가 실패했습니다")
        }

        // A failed write must leave every classification in the batch unchanged.
        try seed("rollback-a", path: "Archive/English/첫자료.pdf")
        try seed("rollback-b", path: "Archive/Astronomy/끝자료.pdf")
        let rollbackDocuments = try database.rows("SELECT * FROM goodnotes_documents ORDER BY id")
        let rollbackClassifications = try database.rows("SELECT * FROM goodnotes_classifications ORDER BY document_id")
        try database.execute("""
            CREATE TRIGGER reject_backfill BEFORE UPDATE ON goodnotes_documents
            WHEN NEW.id = 'doc-rollback-b'
            BEGIN SELECT RAISE(ABORT, 'intentional backfill rejection'); END
            """)
        do {
            _ = try database.reclassifyGoodnotesMaterials()
            throw DatabaseError.sqlite("재분류 트랜잭션 실패가 감지되지 않았습니다")
        } catch {
            guard error.localizedDescription.contains("intentional backfill rejection") else { throw error }
        }
        guard try database.rows("SELECT * FROM goodnotes_documents ORDER BY id") == rollbackDocuments,
              try database.rows("SELECT * FROM goodnotes_classifications ORDER BY document_id") == rollbackClassifications else {
            throw DatabaseError.sqlite("재분류 실패 후 일부 분류만 저장되었습니다")
        }
        try verifyManualRevision(in: directory)
        print("Ravil Goodnotes reclassification check: nested folders, legacy metadata, manual/provided choices, approved OCR, idempotence, rollback, immutable history, and manual revision overrides passed")
    }

    private static func verifyManualRevision(in directory: URL) throws {
        let database = try LibraryDatabase(location: directory.appendingPathComponent("revision.sqlite"),
                                            importLegacy: false)
        let pdf = directory.appendingPathComponent("revision.pdf")
        func makePDF(pageCount: Int) throws {
            var box = CGRect(x: 0, y: 0, width: 100, height: 100)
            guard let consumer = CGDataConsumer(url: pdf as CFURL),
                  let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
                throw DatabaseError.sqlite("재분류 테스트 PDF를 만들지 못했습니다")
            }
            for page in 0..<pageCount {
                context.beginPDFPage(nil)
                context.setFillColor(NSColor(calibratedWhite: CGFloat(page + 1) / 10, alpha: 1).cgColor)
                context.fill(box)
                context.endPDFPage()
            }
            context.closePDF()
        }
        func importRevision(_ revision: Int, teacherInName: String) throws -> GoodnotesImportReport.Item {
            let entry = GoodnotesImportEntry(
                driveFileID: "manual-revision", revisionID: "revision-\(revision)",
                relativePath: "Astronomy/\(teacherInName)_학습지.pdf", localPDFPath: pdf.path,
                sourceURL: "https://drive.google.com/file/d/manual-revision/view",
                sourceModifiedAt: "2026-09-30T00:00:00Z", subject: nil, documentKind: nil)
            return try database.importGoodnotesMidterm(
                GoodnotesImportManifest(midtermRootFolderID: "root", entries: [entry])).items[0]
        }
        try makePDF(pageCount: 1)
        let first = try importRevision(1, teacherInName: "원본T")
        try database.updateGoodnotesClassification(materialID: first.materialID, subject: "영어",
                                                  documentKind: "교재", teacherName: "직접 입력")
        try makePDF(pageCount: 2)
        let second = try importRevision(2, teacherInName: "다른T")
        let secondClassification = try database.rows("SELECT * FROM goodnotes_classifications WHERE document_id = ?",
                                                    values: [second.documentID]).first
        guard second.version == 2, second.createdVersion, second.subject == "영어", second.documentKind == "교재",
              !second.classificationNeedsReview, secondClassification?["teacher_name"] == "직접 입력",
              secondClassification?["confidence"].flatMap(Double.init) == 1,
              secondClassification?["subject_source"] == "manual",
              secondClassification?["kind_source"] == "manual" else {
            throw DatabaseError.sqlite("새 판본이 수동 분류·교사명·신뢰도를 덮어썼습니다")
        }
        try database.updateGoodnotesClassification(materialID: second.materialID, subject: "영어",
                                                  documentKind: "교재", teacherName: nil)
        try makePDF(pageCount: 3)
        let third = try importRevision(3, teacherInName: "다른T")
        let thirdClassification = try database.rows("SELECT * FROM goodnotes_classifications WHERE document_id = ?",
                                                   values: [third.documentID]).first
        guard third.createdVersion, third.version == 3,
              thirdClassification?["teacher_name"] == nil,
              thirdClassification?["confidence"].flatMap(Double.init) == 1,
              try database.goodnotesVersions(for: third.materialID).count == 3 else {
            throw DatabaseError.sqlite("수동으로 비운 교사명 또는 판본 기록이 유지되지 않았습니다")
        }

        let supplied = GoodnotesImportEntry(
            driveFileID: "provided-revision", revisionID: "provided-1", relativePath: "Astronomy/제공자료.pdf",
            localPDFPath: pdf.path, sourceURL: "https://drive.google.com/file/d/provided-revision/view",
            sourceModifiedAt: nil, subject: "천문", documentKind: "교재")
        _ = try database.importGoodnotesMidterm(GoodnotesImportManifest(midtermRootFolderID: "root", entries: [supplied]))
        let conflict = GoodnotesImportEntry(
            driveFileID: "provided-revision", revisionID: "provided-2", relativePath: "English/제공자료.pdf",
            localPDFPath: pdf.path, sourceURL: "https://drive.google.com/file/d/provided-revision/view",
            sourceModifiedAt: nil, subject: nil, documentKind: nil)
        let conflictItem = try database.importGoodnotesMidterm(
            GoodnotesImportManifest(midtermRootFolderID: "root", entries: [conflict])).items[0]
        guard conflictItem.subject == "천문", conflictItem.classificationNeedsReview,
              try database.reclassifyGoodnotesMaterials() == 0,
              try database.rows("SELECT needs_review FROM goodnotes_classifications WHERE document_id = ?",
                                values: [conflictItem.documentID]).first?["needs_review"] == "1" else {
            throw DatabaseError.sqlite("제공한 과목과 폴더의 충돌 경고가 재분류 중 사라졌습니다")
        }
    }
}
