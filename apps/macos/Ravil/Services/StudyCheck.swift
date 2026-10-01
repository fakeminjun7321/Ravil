import AppKit
import Foundation

enum StudyCheck {
    static func run() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("RavilStudyCheck-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pdfURL = folder.appendingPathComponent("source.pdf")
        try makePDF(at: pdfURL, pages: 2)
        let database = try LibraryDatabase(location: folder.appendingPathComponent("study.sqlite"),
                                           importLegacy: false)
        let first = try database.importGoodnotesMidterm(GoodnotesImportManifest(
            midtermRootFolderID: "exam-root",
            entries: [GoodnotesImportEntry(driveFileID: "file-1", revisionID: "rev-1",
                                           relativePath: "Physics/박홍T_학습지.pdf",
                                           localPDFPath: pdfURL.path,
                                           sourceURL: "https://drive.google.com/file/d/file-1/view",
                                           sourceModifiedAt: "2026-09-25T00:00:00Z",
                                           subject: nil, documentKind: nil)]))
        let materialID = first.items[0].materialID
        let scopeID = try database.createExamScope(
            title: "중간고사 일물", examDate: "2026-10-10",
            ranges: [(materialID: materialID, startPage: 1, endPage: 2)])
        guard try database.examScopes().first?.materialCount == 1,
              try database.examMaterials(scopeID: scopeID).first?.subject == "일물" else {
            throw DatabaseError.sqlite("시험 범위 저장·분류 검사가 실패했습니다")
        }
        let firstCard = try database.addQuizCard(scopeID: scopeID, materialID: materialID,
                                                 page: 1, question: "전기장은 무엇인가?", answer: "시험 답")
        let secondCard = try database.addQuizCard(scopeID: scopeID, materialID: materialID,
                                                  page: 2, question: "둘째 문제?", answer: "둘째 답")
        guard let firstShown = try database.nextQuizCard(scopeID: scopeID, excluding: []),
              [firstCard, secondCard].contains(firstShown.id) else {
            throw DatabaseError.sqlite("새 문제 첫 순회 검사가 실패했습니다")
        }
        let secondShownID = firstShown.id == firstCard ? secondCard : firstCard
        try database.recordQuizReview(cardID: firstShown.id, grade: .wrong)
        guard try database.nextQuizCard(scopeID: scopeID, excluding: [firstShown.id])?.id == secondShownID else {
            throw DatabaseError.sqlite("틀린 문제보다 미학습 범위를 우선하지 못했습니다")
        }
        try database.recordQuizReview(cardID: secondShownID, grade: .correct)
        guard try database.nextQuizCard(scopeID: scopeID, excluding: [firstCard, secondCard]) == nil,
              try database.nextQuizCard(scopeID: scopeID, excluding: [])?.id == firstShown.id else {
            throw DatabaseError.sqlite("세션 내 재출제 방지 또는 다음 세션 약점 우선 검사가 실패했습니다")
        }

        try makePDF(at: pdfURL, pages: 3)
        let updated = try database.importGoodnotesMidterm(GoodnotesImportManifest(
            midtermRootFolderID: "exam-root",
            entries: [GoodnotesImportEntry(driveFileID: "file-1", revisionID: "rev-2",
                                           relativePath: "Physics/박홍T_학습지.pdf",
                                           localPDFPath: pdfURL.path,
                                           sourceURL: "https://drive.google.com/file/d/file-1/view",
                                           sourceModifiedAt: "2026-09-25T01:00:00Z",
                                           subject: nil, documentKind: nil)]))
        guard updated.newVersions == 1,
              try database.examMaterials(scopeID: scopeID).first?.sourceIsCurrent == false,
              try database.quizCards(scopeID: scopeID).allSatisfy({ !$0.sourceIsCurrent }),
              try database.nextQuizCard(scopeID: scopeID, excluding: []) == nil else {
            throw DatabaseError.sqlite("PDF 변경 후 이전 판본 카드 경고 검사가 실패했습니다")
        }
        do {
            try database.recordQuizReview(cardID: firstCard, grade: .correct)
            throw DatabaseError.sqlite("오래된 PDF 카드를 다시 평가했습니다")
        } catch {
            guard error.localizedDescription.contains("최신 자료") else { throw error }
        }
        do {
            _ = try database.addQuizCard(scopeID: scopeID, materialID: materialID,
                                         page: 1, question: "오래된 판본", answer: "거부")
            throw DatabaseError.sqlite("오래된 PDF로 새 카드를 만들었습니다")
        } catch {
            guard error.localizedDescription.contains("최신 PDF 페이지") else { throw error }
        }
        try database.rebaseExamScopeMaterial(scopeID: scopeID, oldMaterialID: materialID,
                                             newMaterialID: updated.items[0].materialID,
                                             startPage: 1, endPage: 3)
        guard try database.examMaterials(scopeID: scopeID).first?.sourceIsCurrent == true,
              try database.examMaterials(scopeID: scopeID).first?.endPage == 3,
              try database.nextQuizCard(scopeID: scopeID, excluding: []) == nil else {
            throw DatabaseError.sqlite("최신 판본 시험 범위 재지정 검사가 실패했습니다")
        }
        _ = try database.addQuizCard(scopeID: scopeID, materialID: updated.items[0].materialID,
                                     page: 3, question: "새 판본 문제", answer: "새 판본 답")
        print("Ravil study check: scope, source pages, first-pass coverage, weak review, and stale-source guard passed")
    }

    private static func makePDF(at url: URL, pages: Int) throws {
        var box = CGRect(x: 0, y: 0, width: 150, height: 180)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw DatabaseError.sqlite("테스트 PDF를 만들 수 없습니다")
        }
        for index in 0..<pages {
            context.beginPDFPage(nil)
            context.setFillColor(NSColor(calibratedWhite: CGFloat(index + 1) / 10, alpha: 1).cgColor)
            context.fill(box)
            context.endPDFPage()
        }
        context.closePDF()
    }
}
