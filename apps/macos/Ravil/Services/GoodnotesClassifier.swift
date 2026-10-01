import Foundation

struct GoodnotesClassification {
    let subject: String
    let documentKind: String
    let teacherName: String?
    let subjectSource: String
    let kindSource: String
    let needsReview: Bool
    let confidence: Double
}

enum GoodnotesClassifier {
    static let allowedSubjects: Set<String> = ["켈큘", "천문", "미방", "일물", "현물", "국어", "영어", "물실", "프실"]
    static let unclassifiedSubject = "분류 확인 필요"
    static let unclassifiedKind = "자료 유형 확인 필요"

    static func classify(relativePath: String, firstPageText: String, pageCount: Int,
                         suppliedSubject: String?, suppliedKind: String?) throws -> GoodnotesClassification {
        let path = relativePath.precomposedStringWithCanonicalMapping
        let filename = (path as NSString).lastPathComponent
        // Drive roots often contain a semester or exam folder before the subject.
        // The closest subject folder is the most specific part of that path.
        let folderSubject = path.split(separator: "/").dropLast().reversed()
            .compactMap { canonicalSubject(String($0)) }.first
        let subject: String
        let subjectSource: String
        let confidence: Double
        if let suppliedSubject {
            guard allowedSubjects.contains(suppliedSubject) else {
                throw DatabaseError.sqlite("지원하지 않는 과목입니다: \(suppliedSubject)")
            }
            subject = suppliedSubject
            subjectSource = "provided"
            confidence = 1
        } else if let byFolder = folderSubject {
            subject = byFolder
            subjectSource = "folder"
            confidence = 0.99
        } else {
            let filenameMatches = subjectMatches(in: filename)
            if filenameMatches.count == 1, let match = filenameMatches.first {
                subject = match
                subjectSource = "filename"
                confidence = 0.8
            } else if filenameMatches.isEmpty {
                let contentMatches = subjectMatches(in: String(firstPageText.prefix(1_200)))
                if contentMatches.count == 1, let match = contentMatches.first {
                    subject = match
                    subjectSource = "first_page"
                    confidence = 0.65
                } else {
                    subject = unclassifiedSubject
                    subjectSource = "review"
                    confidence = 0
                }
            } else {
                subject = unclassifiedSubject
                subjectSource = "review"
                confidence = 0
            }
        }

        let kind: String
        let kindSource: String
        if let suppliedKind {
            let value = suppliedKind.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.count <= 80,
                  value.rangeOfCharacter(from: .controlCharacters) == nil else {
                throw DatabaseError.sqlite("자료 종류가 비어 있거나 유효하지 않습니다")
            }
            kind = value
            kindSource = "provided"
        } else if let byName = documentKind(filename: filename, firstPageText: firstPageText) {
            kind = byName
            kindSource = "filename"
        } else {
            kind = unclassifiedKind
            kindSource = "review"
        }
        let teacher = teacherName(in: filename)
        let possiblyBlankSinglePage = pageCount == 1 &&
            firstPageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            suppliedKind == nil
        return GoodnotesClassification(subject: subject, documentKind: kind,
                                       teacherName: teacher, subjectSource: subjectSource,
                                       kindSource: kindSource,
                                       needsReview: subject == unclassifiedSubject || kind == unclassifiedKind
                                           || subjectSource == "first_page" || possiblyBlankSinglePage,
                                       confidence: confidence)
    }

    static func canonicalSubject(_ name: String) -> String? {
        switch normalized(name) {
        case "math", "mathematics", "calculus", "calculus1", "calculus2", "calculus3",
             "calculusi", "calculusii", "calculusiii", "켈큘", "캘큘", "미적분", "미적분학",
             "수1", "수2", "수3", "수i", "수ii", "수iii": return "켈큘"
        case "astronomy", "천문", "천문학", "일지", "일지1", "일지i": return "천문"
        case "differentialequation", "differentialequations", "ordinarydifferentialequations",
             "미방", "미분방정식": return "미방"
        case "physics", "generalphysics", "generalphysics1", "generalphysics2",
             "generalphysicsi", "generalphysicsii", "일물", "일반물리", "일반물리학": return "일물"
        case "modernphysics", "현물", "현대물리", "현대물리학": return "현물"
        case "korean", "국어", "독서", "독서토론": return "국어"
        case "english", "english1", "english2", "englishi", "englishii", "영어",
             "영1", "영2", "영i", "영ii": return "영어"
        case "physicslab", "physicslaboratory", "generalphysicslab", "generalphysicslaboratory",
             "물실", "물리실험", "물리학실험", "일반물리실험", "일반물리학실험": return "물실"
        case "projectlab", "projectlaboratory", "프실", "프로젝트실험": return "프실"
        default: return nil
        }
    }

    private static func subjectMatches(in text: String) -> Set<String> {
        let value = normalized(text)
        let clues: [(String, [String])] = [
            ("켈큘", ["calculus", "미적분", "켈큘", "캘큘"]),
            ("천문", ["astronomy", "천문", "천체의좌표계"]),
            ("미방", ["differentialequation", "미분방정식", "미방"]),
            ("일물", ["generalphysics", "일반물리", "일물", "electricfields"]),
            ("현물", ["modernphysics", "현대물리", "현물", "quantummechanics"]),
            ("국어", ["국어", "독서토론"]),
            ("영어", ["영어", "english"]),
            ("물실", ["generalphysicslaboratory", "generalphysicslab", "physicslaboratory", "physicslab",
                      "일반물리학실험", "일반물리실험", "물리학실험", "물리실험", "물실"]),
            ("프실", ["projectlaboratory", "projectlab", "프실", "프로젝트실험"])
        ]
        let text = value as NSString
        var matches: [(subject: String, range: NSRange)] = []
        for (subject, terms) in clues {
            for term in terms {
                var remaining = NSRange(location: 0, length: text.length)
                while remaining.length > 0 {
                    let range = text.range(of: term, options: .literal, range: remaining)
                    guard range.location != NSNotFound else { break }
                    matches.append((subject, range))
                    let next = NSMaxRange(range)
                    remaining = NSRange(location: next, length: text.length - next)
                }
            }
        }
        // A longer course name owns the text it contains: 일반물리학실험 and
        // General Physics Lab are 물실. Separate mentions still stay ambiguous.
        return Set(matches.filter { candidate in
            !matches.contains { other in
                other.range.length > candidate.range.length
                    && other.range.location <= candidate.range.location
                    && NSMaxRange(other.range) >= NSMaxRange(candidate.range)
            }
        }.map(\.subject))
    }

    private static func documentKind(filename: String, firstPageText: String) -> String? {
        let value = normalized(filename)
        if value.contains("답지") || value.contains("정답") || value.hasSuffix("답pdf") { return "정답" }
        if value.contains("교수학습") || value.contains("운영계획") || value.contains("평가계획") {
            return "수업·평가 계획"
        }
        if value.contains("교안") { return "교안" }
        if value.contains("직보") { return "시험 직전 자료" }
        if value.contains("학원") && value.contains("자료") { return "학원 자료" }
        if value.contains("정리노트") || value.contains("정리pdf") { return "정리노트" }
        if value.contains("학습지") { return "학습지" }
        if value.contains("textbook") || value.contains("교재") || value.contains("differentialequation11e")
            || firstPageText.lowercased().contains("a first course in differential equations") {
            return "교재"
        }
        if value.contains("자료") { return "자료" }
        return nil
    }

    private static func teacherName(in filename: String) -> String? {
        let pattern = "[가-힣]{2,4}T"
        guard let range = filename.range(of: pattern, options: .regularExpression) else { return nil }
        return String(filename[range])
    }

    private static func normalized(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping.lowercased()
            .replacingOccurrences(of: "[^\\p{L}\\p{N}]+", with: "", options: .regularExpression)
    }
}
