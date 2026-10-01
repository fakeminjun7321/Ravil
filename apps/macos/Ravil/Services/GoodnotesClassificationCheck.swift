import Foundation

enum GoodnotesClassificationCheck {
    static func run() throws {
        func classify(_ path: String, text: String = "", supplied: String? = nil) throws -> GoodnotesClassification {
            try GoodnotesClassifier.classify(relativePath: path, firstPageText: text, pageCount: 2,
                                             suppliedSubject: supplied, suppliedKind: "학습지")
        }
        func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            guard try condition() else { throw DatabaseError.sqlite(message) }
        }

        let nested = try classify("2026/2학기/중간고사/천문/이영훈T/학습지.pdf")
        try expect(nested.subject == "천문" && nested.subjectSource == "folder",
                   "학기·시험·교사 폴더 안의 과목을 찾지 못했습니다")
        let specific = try classify("Physics/Modern Physics/김제훈T/학습지.pdf")
        try expect(specific.subject == "현물", "가장 가까운 과목 폴더를 우선하지 않았습니다")
        let differential = try classify("Mathematics/Differential Equations/학습지.pdf")
        try expect(differential.subject == "미방", "수학 하위의 미분방정식 폴더를 구분하지 못했습니다")
        let folderPriority = try classify("미방/영어 학습지.pdf", text: "일반물리학")
        try expect(folderPriority.subject == "미방", "과목 폴더보다 파일명·본문을 우선했습니다")

        let aliases: [(String, String)] = [
            ("  Calculus II  ", "켈큘"), ("수 Ⅲ", "켈큘"), ("일지 Ⅰ", "천문"),
            ("Differential Equations", "미방"), ("일반 물리학", "일물"),
            ("Modern-Physics", "현물"), ("독서", "국어"), ("영 Ⅱ", "영어"),
            ("General Physics Laboratory", "물실"), ("프로젝트 실험", "프실")
        ]
        for (alias, subject) in aliases {
            try expect(GoodnotesClassifier.canonicalSubject(alias) == subject,
                       "과목 별칭을 정규화하지 못했습니다: \(alias)")
        }
        try expect(GoodnotesClassifier.canonicalSubject("일물 현물") == nil,
                   "여러 과목이 적힌 폴더를 하나의 과목으로 확정했습니다")
        let decomposed = "보관/현대물리학/학습지.pdf".decomposedStringWithCanonicalMapping
        try expect(try classify(decomposed).subject == "현물", "분해된 한글 경로를 인식하지 못했습니다")

        for path in ["일반물리학실험 학습지.pdf", "Archive/General Physics Laboratory.pdf",
                     "물리학실험/학습지.pdf"] {
            try expect(try classify(path).subject == "물실", "물리실험을 일반물리로 분류했습니다: \(path)")
        }
        try expect(try classify("Modern Physics 학습지.pdf").subject == "현물",
                   "Modern Physics 파일명을 현대물리로 분류하지 못했습니다")
        let separatePhysics = try classify("일반물리학실험 및 일반물리 학습지.pdf")
        try expect(separatePhysics.subject == GoodnotesClassifier.unclassifiedSubject,
                   "별도로 언급된 일반물리와 실험 과목의 모호함을 무시했습니다")
        let ambiguous = try classify("국어 영어 자료.pdf", text: "영어")
        try expect(ambiguous.subject == GoodnotesClassifier.unclassifiedSubject && ambiguous.needsReview,
                   "모호한 파일명을 본문 추정으로 강제 분류했습니다")
        let unknown = try classify("보관/시험/무제.pdf")
        try expect(unknown.subject == GoodnotesClassifier.unclassifiedSubject && unknown.needsReview,
                   "단서 없는 자료가 확인 대상으로 남지 않았습니다")
        let content = try classify("보관/학습지.pdf", text: "현대물리학\n양자역학의 기초")
        try expect(content.subject == "현물" && content.subjectSource == "first_page" && content.needsReview,
                   "첫 페이지 분류 또는 검토 표시가 잘못됐습니다")
        let supplied = try classify("영어/영어 학습지.pdf", supplied: "국어")
        try expect(supplied.subject == "국어" && supplied.subjectSource == "provided" && supplied.confidence == 1,
                   "명시한 과목을 자동 분류가 덮어썼습니다")
        do {
            _ = try classify("자료.pdf", supplied: "알 수 없는 과목")
            throw DatabaseError.sqlite("지원하지 않는 명시 과목을 수락했습니다")
        } catch {
            guard error.localizedDescription.contains("지원하지 않는 과목입니다") else { throw error }
        }

        print("Ravil Goodnotes classification check: nested folders, subject aliases, Unicode, specificity, ambiguity, content and explicit overrides passed")
    }
}
