import Foundation

struct LectureBookmark: Identifiable, Codable, Hashable {
    var id: String = UUID().uuidString
    let lectureID: String
    let milliseconds: Int
    let materialID: String?
    let page: Int?
    var note: String
}

struct BrainSource: Identifiable, Codable, Hashable {
    let id: String
    let kind: String
    let targetID: String
    let title: String
    let text: String
    let milliseconds: Int?
    let page: Int?
    var location: String {
        if let page { return "\(page)쪽" }
        if let milliseconds { return String(format: "%02d:%02d", milliseconds / 60000, milliseconds / 1000 % 60) }
        return "노트"
    }
}

struct BrainAnswer: Identifiable, Codable {
    var id: String = UUID().uuidString
    let question: String
    let answer: String
    let sources: [BrainSource]
    let createdAt: Date
}
