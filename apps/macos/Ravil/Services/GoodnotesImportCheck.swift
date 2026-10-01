import AppKit
import Foundation

enum GoodnotesImportCheck {
    static func run() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("RavilGoodnotesCheck-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = try LibraryDatabase(location: folder.appendingPathComponent("test.sqlite"), importLegacy: false)
        let pdfURL = folder.appendingPathComponent("download.pdf")
        try makePDF(at: pdfURL, pageCount: 1)

        func entry(fileID: String = "drive-file-1", path: String = "Mathematics/Midterm.pdf",
                   revision: String = "revision-1",
                   modified: String = "2026-09-25T00:00:00Z") -> GoodnotesImportEntry {
            GoodnotesImportEntry(driveFileID: fileID, revisionID: revision, relativePath: path,
                                 localPDFPath: pdfURL.path,
                                 sourceURL: "https://drive.google.com/file/d/\(fileID)/view",
                                 sourceModifiedAt: modified, subject: "켈큘",
                                 documentKind: "worksheet")
        }
        func manifest(_ entries: [GoodnotesImportEntry]) -> GoodnotesImportManifest {
            GoodnotesImportManifest(midtermRootFolderID: "midterm-root-1", entries: entries)
        }

        let first = try database.importGoodnotesMidterm(manifest([entry()]))
        let repeatImport = try database.importGoodnotesMidterm(manifest([entry()]))
        let metadataOnly = try database.importGoodnotesMidterm(
            manifest([entry(modified: "2026-09-25T00:01:00Z")]))
        guard first.newVersions == 1, repeatImport.newVersions == 0,
              metadataOnly.newVersions == 0,
              first.items[0].documentID == repeatImport.items[0].documentID,
              first.items[0].materialID == repeatImport.items[0].materialID,
              try database.materials().count == 1,
              try database.materials().first?.course == "켈큘" else {
            throw DatabaseError.sqlite("굿노트 동일 PDF 재수입 검사가 실패했습니다")
        }
        let firstOCR = try database.runGoodnotesOCR(limit: 1)
        let repeatedOCR = try database.runGoodnotesOCR(limit: 1)
        guard firstOCR.attempted == 1, firstOCR.failed == 0,
              repeatedOCR.attempted == 0,
              try database.rows("SELECT COUNT(*) AS n FROM material_page_ocr").first?["n"] == "1" else {
            throw DatabaseError.sqlite("기기 내 OCR 저장 또는 중복 처리 검사가 실패했습니다")
        }
        let originalPath = try database.rows("SELECT local_path FROM course_materials WHERE id = ?",
                                             values: [first.items[0].materialID]).first?["local_path"]

        try makePDF(at: pdfURL, pageCount: 2)
        let changed = try database.importGoodnotesMidterm(manifest([entry(revision: "revision-2")]))
        let changedPath = try database.rows("SELECT local_path FROM course_materials WHERE id = ?",
                                            values: [changed.items[0].materialID]).first?["local_path"]
        guard changed.newVersions == 1, changed.items[0].version == 2,
              changed.items[0].documentID == first.items[0].documentID,
              changed.items[0].materialID != first.items[0].materialID,
              try database.materials().count == 1,
              try database.search("Midterm").filter({ $0.kind == .material }).count == 1,
              let originalPath, FileManager.default.fileExists(atPath: originalPath),
              let changedPath, originalPath != changedPath,
              FileManager.default.fileExists(atPath: changedPath) else {
            throw DatabaseError.sqlite("굿노트 PDF 개정판 또는 과거 파일 보존 검사가 실패했습니다")
        }
        let history = try database.goodnotesVersions(for: changed.items[0].materialID)
        let changeSummary = try database.goodnotesChangeSummary(for: changed.items[0].materialID)
        let visualChange = try GoodnotesVisualDiff.compare(previousPath: originalPath,
                                                          currentPath: changedPath)
        guard history.map(\.version) == [2, 1],
              changeSummary?.pageDelta == 1,
              changeSummary?.definitelyAddedPages.isEmpty == true,
              visualChange.locationsCertain, visualChange.addedPages == [2] else {
            throw DatabaseError.sqlite("PDF 판본 목록 또는 변경 비교 검사가 실패했습니다")
        }
        let editedPageURL = folder.appendingPathComponent("edited-page.pdf")
        try makePDF(at: editedPageURL, pageCount: 2, changedPage: 1)
        let sameLengthChange = try GoodnotesVisualDiff.compare(previousPath: changedPath,
                                                               currentPath: editedPageURL.path)
        guard sameLengthChange.locationsCertain,
              sameLengthChange.changedPages == [2] else {
            throw DatabaseError.sqlite("같은 쪽수의 그림 변경 검사가 실패했습니다")
        }

        try makePDF(at: pdfURL, pageCount: 3)
        let replacement = try database.importGoodnotesMidterm(
            manifest([entry(fileID: "drive-file-2", revision: "revision-3")]))
        guard replacement.items[0].documentID == first.items[0].documentID,
              replacement.items[0].version == 3,
              replacement.newVersions == 1,
              try database.materials().first?.pageCount == 3 else {
            throw DatabaseError.sqlite("Drive ID 교체 후 동일 문서 버전 연결 검사가 실패했습니다")
        }

        let renamed = try database.importGoodnotesMidterm(
            manifest([entry(fileID: "drive-file-2", path: "Mathematics/Midterm-renamed.pdf",
                            revision: "revision-3")]))
        guard renamed.items[0].documentID == first.items[0].documentID,
              renamed.newVersions == 0,
              try database.materials().first?.title == "Midterm-renamed.pdf" else {
            throw DatabaseError.sqlite("같은 Drive ID의 이름 변경 검사가 실패했습니다")
        }

        do {
            _ = try database.importGoodnotesMidterm(manifest([
                entry(fileID: "drive-file-3", path: "Duplicate.pdf"),
                entry(fileID: "drive-file-4", path: "duplicate.PDF")
            ]))
            throw DatabaseError.sqlite("중복 경로가 거부되지 않았습니다")
        } catch {
            guard error.localizedDescription.contains("중복된 중간고사 상대 경로") else { throw error }
        }
        do {
            _ = try database.importGoodnotesMidterm(manifest([entry(path: "../outside.pdf")]))
            throw DatabaseError.sqlite("루트 밖 상대 경로가 거부되지 않았습니다")
        } catch {
            guard error.localizedDescription.contains("안전한 PDF 상대 경로") else { throw error }
        }

        let other = try database.importGoodnotesMidterm(
            manifest([entry(fileID: "drive-file-3", path: "Other.pdf")]))
        guard other.items[0].documentID != first.items[0].documentID else {
            throw DatabaseError.sqlite("별도 PDF가 잘못 병합되었습니다")
        }
        do {
            _ = try database.importGoodnotesMidterm(
                manifest([entry(fileID: "drive-file-3", path: "Mathematics/Midterm-renamed.pdf")]))
            throw DatabaseError.sqlite("충돌하는 파일 ID/경로가 거부되지 않았습니다")
        } catch {
            guard error.localizedDescription.contains("서로 다른 문서") else { throw error }
        }
        guard try database.rows("SELECT COUNT(*) AS n FROM goodnotes_versions").first?["n"] == "4",
              try database.rows("SELECT COUNT(*) AS n FROM goodnotes_documents").first?["n"] == "2" else {
            throw DatabaseError.sqlite("충돌 실패 후 DB 버전 수가 변경되었습니다")
        }

        try Data("not a PDF".utf8).write(to: pdfURL)
        do {
            _ = try database.importGoodnotesMidterm(
                manifest([entry(fileID: "drive-file-2", path: "Mathematics/Midterm-renamed.pdf")]))
            throw DatabaseError.sqlite("손상된 PDF가 수락되었습니다")
        } catch {
            guard error.localizedDescription.contains("PDF를 읽을 수 없") else { throw error }
        }
        guard try database.rows("""
            SELECT current_material_id FROM goodnotes_documents WHERE id = ?
            """, values: [first.items[0].documentID]).first?["current_material_id"] == replacement.items[0].materialID,
              try database.rows("SELECT COUNT(*) AS n FROM goodnotes_source_observations").first?["n"] == "6" else {
            throw DatabaseError.sqlite("실패 후 최신 버전 또는 출처 관찰 기록이 손상되었습니다")
        }
        try makePDF(at: pdfURL, pageCount: 1)
        let automaticDB = try LibraryDatabase(location: folder.appendingPathComponent("auto.sqlite"),
                                              importLegacy: false)
        let automatic = GoodnotesImportEntry(
            driveFileID: "auto-1", revisionID: "auto-rev-1",
            relativePath: "Astronomy/배태윤T_학습지.pdf", localPDFPath: pdfURL.path,
            sourceURL: "https://drive.google.com/file/d/auto-1/view",
            sourceModifiedAt: "2026-09-25T00:00:00Z", subject: nil, documentKind: nil)
        let automaticReport = try automaticDB.importGoodnotesMidterm(
            GoodnotesImportManifest(midtermRootFolderID: "midterm-root-1", entries: [automatic]))
        guard automaticReport.items.first?.subject == "천문",
              automaticReport.items.first?.documentKind == "학습지",
              automaticReport.items.first?.classificationSource == "folder",
              automaticReport.items.first?.classificationNeedsReview == true,
              try automaticDB.materials().first?.teacherName == "배태윤T" else {
            throw DatabaseError.sqlite("폴더·파일명 자동 분류 검사가 실패했습니다")
        }
        let automaticMaterialID = automaticReport.items[0].materialID
        let reviewOCR = try automaticDB.runGoodnotesOCR(limit: 1)
        guard reviewOCR.attempted == 1, reviewOCR.failed == 0,
              let reviewPage = try automaticDB.goodnotesOCRPages(for: automaticMaterialID).first else {
            throw DatabaseError.sqlite("OCR 검토 대상 페이지를 만들지 못했습니다")
        }
        try automaticDB.approveGoodnotesOCR(pageID: reviewPage.id,
                                           materialID: automaticMaterialID,
                                           correctedText: "검증 키워드")
        guard try automaticDB.goodnotesOCRPages(for: automaticMaterialID).first?.correctedText == "검증 키워드",
              try automaticDB.goodnotesOCRStatus(for: automaticMaterialID)?.approvedPages == 1,
              try automaticDB.search("검증 키워드").contains(where: {
                  $0.kind == .material && $0.targetID == automaticMaterialID && $0.pageNumber == 1
              }) else {
            throw DatabaseError.sqlite("OCR 수정·승인·검색 검사가 실패했습니다")
        }
        let unknown = GoodnotesImportEntry(
            driveFileID: "auto-2", revisionID: "auto-rev-1",
            relativePath: "Archive/Mystery.pdf", localPDFPath: pdfURL.path,
            sourceURL: "https://drive.google.com/file/d/auto-2/view",
            sourceModifiedAt: "2026-09-25T00:00:00Z", subject: nil, documentKind: nil)
        let unknownReport = try automaticDB.importGoodnotesMidterm(
            GoodnotesImportManifest(midtermRootFolderID: "midterm-root-1", entries: [unknown]))
        guard unknownReport.items.first?.subject == GoodnotesClassifier.unclassifiedSubject,
              unknownReport.items.first?.classificationNeedsReview == true else {
            throw DatabaseError.sqlite("모호한 PDF가 분류 확인 대상으로 남지 않았습니다")
        }
        let targetedOCR = try automaticDB.runGoodnotesOCR(limit: 1,
                                                          materialID: unknownReport.items[0].materialID)
        guard targetedOCR.attempted == 1, targetedOCR.failed == 0,
              try automaticDB.goodnotesOCRStatus(for: unknownReport.items[0].materialID)?.processedPages == 1,
              try automaticDB.goodnotesOCRStatus(for: automaticMaterialID)?.processedPages == 1 else {
            throw DatabaseError.sqlite("선택한 PDF만 OCR하는 검사가 실패했습니다")
        }
        try automaticDB.updateGoodnotesClassification(materialID: automaticMaterialID,
                                                       subject: "천문", documentKind: "학습지",
                                                       teacherName: "배태윤T")
        guard try automaticDB.materials().first(where: { $0.id == automaticMaterialID })?.classificationNeedsReview == false else {
            throw DatabaseError.sqlite("수동 분류 확인 상태가 저장되지 않았습니다")
        }
        try makePDF(at: pdfURL, pageCount: 2)
        let nextAutomatic = GoodnotesImportEntry(
            driveFileID: "auto-1", revisionID: "auto-rev-2",
            relativePath: "Astronomy/배태윤T_학습지.pdf", localPDFPath: pdfURL.path,
            sourceURL: "https://drive.google.com/file/d/auto-1/view",
            sourceModifiedAt: "2026-09-25T01:00:00Z", subject: nil, documentKind: nil)
        let afterRevision = try automaticDB.importGoodnotesMidterm(
            GoodnotesImportManifest(midtermRootFolderID: "midterm-root-1", entries: [nextAutomatic]))
        guard afterRevision.newVersions == 1,
              afterRevision.items[0].subject == "천문",
              afterRevision.items[0].documentKind == "학습지",
              afterRevision.items[0].classificationNeedsReview == false,
              try automaticDB.rows("SELECT subject_source FROM goodnotes_classifications WHERE document_id = ?",
                                   values: [afterRevision.items[0].documentID]).first?["subject_source"] == "manual" else {
            throw DatabaseError.sqlite("새 PDF 판본이 수동 분류 결정을 덮어썼습니다")
        }
        print("Ravil Goodnotes import check: auto classification, review queue, versions, visual diff, rename, replacement ID, ambiguity, rollback, and OCR passed")
    }

    private static func makePDF(at url: URL, pageCount: Int, changedPage: Int? = nil) throws {
        var box = CGRect(x: 0, y: 0, width: 150, height: 180)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw DatabaseError.sqlite("테스트 PDF를 만들 수 없습니다")
        }
        for page in 0..<pageCount {
            context.beginPDFPage(nil)
            let shade = CGFloat(page + 1 + (changedPage == page ? 1 : 0)) / 10
            context.setFillColor(NSColor(calibratedWhite: shade, alpha: 1).cgColor)
            context.fill(box)
            context.endPDFPage()
        }
        context.closePDF()
    }
}
