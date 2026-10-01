import Foundation

struct SubjectCourseGroup: Identifiable, Hashable {
    let id: String
    let title: String
    let courses: [CourseItem]

    var courseIDs: Set<String> { Set(courses.map(\.id)) }
    var altFolderName: String { id == "calc" ? "캘큘" : title }

    func contains(_ material: MaterialItem) -> Bool {
        // Goodnotes keeps its confirmed subject independently of a lecture course ID.
        if let subject = GoodnotesClassifier.canonicalSubject(material.course) {
            return subject == title
        }
        return material.courseID.map(courseIDs.contains) ?? false
    }

    func contains(_ lecture: LectureItem) -> Bool {
        if let folder = lecture.altFolderName,
           let subject = GoodnotesClassifier.canonicalSubject(folder) {
            return subject == title
        }
        if let courseID = lecture.courseID, courseIDs.contains(courseID) { return true }
        return GoodnotesClassifier.canonicalSubject(lecture.course) == title
    }
    var fallbackColorHue: Int {
        switch id {
        case "calc", "differential": return 51
        case "korean", "english": return 154
        case "astronomy": return 257
        case "physics", "modern-physics": return 309
        case "lab": return 200
        case "project": return 25
        default: return 240
        }
    }

    static func make(from courses: [CourseItem]) -> [SubjectCourseGroup] {
        CourseGrouping.definitions.map { definition in
            let members = courses.filter {
                definition.aliases.contains(normalizeCourseName($0.name))
                    || GoodnotesClassifier.canonicalSubject($0.name) == definition.title
            }
            return SubjectCourseGroup(id: definition.id, title: definition.title, courses: members)
        }
    }
}

private enum CourseGrouping {
    struct Definition {
        let id: String
        let title: String
        let aliases: Set<String>
    }

    static let definitions = [
        Definition(id: "calc", title: "켈큘", aliases: [
            "캘큘", "켈큘", "수1", "수i", "수2", "수ii", "수3", "수iii"
        ]),
        Definition(id: "astronomy", title: "천문", aliases: [
            "천문", "일지1", "일지i"
        ]),
        Definition(id: "differential", title: "미방", aliases: ["미방"]),
        Definition(id: "physics", title: "일물", aliases: ["일물"]),
        Definition(id: "modern-physics", title: "현물", aliases: ["현물"]),
        Definition(id: "korean", title: "국어", aliases: [
            "국어", "독서"
        ]),
        Definition(id: "english", title: "영어", aliases: [
            "영어", "영1", "영i", "영2", "영ii"
        ]),
        Definition(id: "lab", title: "물실", aliases: ["물실"]),
        Definition(id: "project", title: "프실", aliases: ["프실"])
    ]

}

private func normalizeCourseName(_ name: String) -> String {
    name.lowercased()
        .components(separatedBy: .whitespacesAndNewlines)
        .joined()
        .replacingOccurrences(of: "Ⅰ", with: "i")
        .replacingOccurrences(of: "Ⅱ", with: "ii")
        .replacingOccurrences(of: "Ⅲ", with: "iii")
}
