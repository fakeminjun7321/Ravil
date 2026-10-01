import Foundation

struct LectureItem: Identifiable, Hashable {
    let id: String
    let title: String
    let date: String
    let courseID: String?
    let course: String
    let audioPath: String?
    let status: String
    let altFolderName: String?
    let altNoteType: String?
    let canTranscribe: Bool

    var subjectName: String? {
        if let altFolderName, !altFolderName.isEmpty {
            return altFolderName.precomposedStringWithCanonicalMapping == "캘큘" ? "켈큘" : altFolderName
        }
        return course.isEmpty ? nil : course
    }

    var displaySubjectName: String { subjectName ?? "폴더 없음" }

    var symbol: String {
        if altNoteType == "slide" { return "rectangle.on.rectangle" }
        return audioPath == nil ? "doc.text" : "waveform"
    }
}

struct AltSlideSource: Equatable {
    let noteID: String
    let componentID: String
    let extractedText: String
    let localPDFPath: String?
    let mimeType: String?
}

struct CourseItem: Identifiable, Hashable {
    let id: String
    let name: String
}

struct TranscriptItem: Identifiable, Hashable {
    let id: String
    let startMilliseconds: Int
    let endMilliseconds: Int
    let text: String
    let speaker: String?

    var clock: String {
        let total = startMilliseconds / 1_000
        return String(format: "%02d:%02d:%02d", total / 3_600, (total / 60) % 60, total % 60)
    }
}

struct MaterialItem: Identifiable, Hashable, Sendable {
    let id: String
    let lectureID: String?
    let courseID: String?
    let title: String
    let course: String
    let status: String
    let pageCount: Int?
    let localPath: String?
    let externalURL: String?
    let documentKind: String?
    let teacherName: String?
    let classificationNeedsReview: Bool
}

struct GoodnotesVersionItem: Identifiable, Hashable {
    var id: String { materialID }
    let materialID: String
    let version: Int
    let pageCount: Int
    let localPath: String
    let contentHash: String
    let sourceModifiedAt: String?
}

struct GoodnotesChangeSummary: Equatable {
    let previousVersion: Int
    let currentVersion: Int
    let previousPages: Int
    let currentPages: Int
    let definitelyAddedPages: [Int]

    var pageDelta: Int { currentPages - previousPages }
}

struct MaterialOCRStatus: Equatable {
    let candidatePages: Int
    let processedPages: Int
    let lowConfidencePages: Int
    let approvedPages: Int
}

struct MaterialOCRPage: Identifiable, Equatable {
    let id: String
    let pageNumber: Int
    let rawText: String
    let meanConfidence: Double
    let correctedText: String?
    let approvedAt: String?
}

struct ExamScopeItem: Identifiable, Hashable {
    let id: String
    let title: String
    let examDate: String?
    let materialCount: Int
    let cardCount: Int
}

struct ExamMaterialRange: Identifiable, Hashable {
    var id: String { materialID }
    let materialID: String
    let title: String
    let subject: String
    let startPage: Int
    let endPage: Int
    let pageCount: Int
    let sourceIsCurrent: Bool
    let replacementMaterialID: String?
    let replacementPageCount: Int?
    let replacementLocalPath: String?
}

struct QuizCardItem: Identifiable, Hashable {
    let id: String
    let scopeID: String
    let question: String
    let answer: String
    let materialID: String
    let materialTitle: String
    let materialPath: String?
    let sourcePage: Int
    let sourceVersion: Int
    let sourceIsCurrent: Bool
    let reviewCount: Int
    let wrongCount: Int
    let lastGrade: String?
}

enum QuizGrade: String, CaseIterable {
    case wrong = "틀림"
    case unsure = "헷갈림"
    case correct = "맞음"
}

struct KnowledgeNote: Identifiable, Hashable {
    let id: String
    var title: String
    var body: String
    var updatedAt: String
}

struct SearchHit: Identifiable, Hashable {
    enum Kind: String { case lecture, transcript, material, note }
    let id: String
    let kind: Kind
    let title: String
    let excerpt: String
    let targetID: String
    let startMilliseconds: Int?
    var pageNumber: Int? = nil
}

struct TranscriptEvidence: Decodable {
    let sourceType: String?
    let transcriptSegmentId: String?
    let startMs: Int?
    let endMs: Int?
    let quote: String?
}

struct IntelligenceCandidate: Decodable, Identifiable {
    var id: String { "\(evidence?.transcriptSegmentId ?? text):\(text)" }
    let status: String
    let text: String
    let evidence: TranscriptEvidence?
}

struct KeyConcept: Decodable, Identifiable {
    var id: String { name }
    let name: String
    let mentionCount: Int
    let evidence: [TranscriptEvidence]
}

struct StudyPriority: Decodable, Identifiable {
    var id: String { concept }
    let concept: String
    let score: Int
    let level: String
}

struct LectureIntelligence: Decodable {
    struct Summary: Decodable { let status: String; let text: String }
    struct Verification: Decodable { let sourceChanged: Bool? }
    let summary: Summary
    let keyConcepts: [KeyConcept]
    let professorEmphasis: [IntelligenceCandidate]
    let examMentions: [IntelligenceCandidate]
    let assignments: [IntelligenceCandidate]
    let studyPriorities: [StudyPriority]
    let verification: Verification?
}

struct RecognizedPhrase: Decodable {
    struct Offsets: Decodable { let from: Int; let to: Int }
    let offsets: Offsets
    let text: String
}

struct WhisperOutput: Decodable { let transcription: [RecognizedPhrase] }
