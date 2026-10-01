import AppKit
import Foundation
import PDFKit

enum SubjectFolderCheck {
    static func run() throws {
        let courses = [CourseItem(id: "math", name: "수 Ⅱ"),
                       CourseItem(id: "english", name: "영 I"),
                       CourseItem(id: "physics", name: "일물")]
        let groups = SubjectCourseGroup.make(from: courses)
        func material(_ subject: String, courseID: String? = nil) -> MaterialItem {
            MaterialItem(id: UUID().uuidString, lectureID: nil, courseID: courseID,
                         title: "학습지.pdf", course: subject, status: "ingested", pageCount: 2,
                         localPath: nil, externalURL: nil, documentKind: "학습지",
                         teacherName: nil, classificationNeedsReview: false)
        }
        for subject in GoodnotesClassifier.allowedSubjects {
            let matches = groups.filter { $0.contains(material(subject)) }
            guard matches.count == 1, matches[0].title == subject else {
                throw DatabaseError.sqlite("강의 courseID가 없는 Drive 자료의 과목 폴더 연결 실패: \(subject)")
            }
        }
        let cases = [("캘큘", "calc"), ("Modern Physics", "modern-physics"),
                     ("일반물리학실험", "lab"), ("영 Ⅱ", "english")]
        for (alias, id) in cases {
            guard groups.filter({ $0.contains(material(alias)) }).map(\.id) == [id] else {
                throw DatabaseError.sqlite("자료 과목 별칭의 폴더 연결 실패: \(alias)")
            }
        }
        guard groups.filter({ $0.contains(material("", courseID: "math")) }).map(\.id) == ["calc"],
              groups.filter({ $0.contains(material("현물", courseID: "physics")) }).map(\.id) == ["modern-physics"],
              groups.allSatisfy({ !$0.contains(material(GoodnotesClassifier.unclassifiedSubject)) }) else {
            throw DatabaseError.sqlite("과목 폴더가 기존 로컬 PDF, 명시된 분류 또는 미분류 자료를 잘못 처리했습니다")
        }
        let lecture = LectureItem(id: "lecture", title: "강의", date: "2026-09-30",
                                  courseID: "physics", course: "일물", audioPath: nil,
                                  status: "ready", altFolderName: "현물", altNoteType: nil,
                                  canTranscribe: false)
        guard groups.filter({ $0.contains(lecture) }).map(\.id) == ["modern-physics"] else {
            throw DatabaseError.sqlite("강의의 원본 과목 폴더 구분이 유지되지 않았습니다")
        }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("RavilSubjectFolderCheck-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = try LibraryDatabase(location: folder.appendingPathComponent("test.sqlite"), importLegacy: false)
        let pdfURL = folder.appendingPathComponent("자료.pdf")
        var pageBox = CGRect(x: 0, y: 0, width: 150, height: 180)
        guard let consumer = CGDataConsumer(url: pdfURL as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &pageBox, nil) else {
            throw DatabaseError.sqlite("과목 폴더 검사 PDF를 만들 수 없습니다")
        }
        context.beginPDFPage(nil)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(pageBox)
        context.endPDFPage()
        context.closePDF()

        let imported = try database.importLocalPDF(from: pdfURL, courseID: nil, subjectName: "현물")
        let repeated = try database.importLocalPDF(from: pdfURL, courseID: nil, subjectName: "현물")
        let reopened = try LibraryDatabase(location: folder.appendingPathComponent("test.sqlite"), importLegacy: false)
        let saved = try reopened.materials().first(where: { $0.id == imported.id })
        let refreshedGroups = SubjectCourseGroup.make(from: try reopened.courses())
        guard imported.id == repeated.id, imported.course == "현물", imported.courseID != nil,
              let saved, saved.courseID == imported.courseID,
              refreshedGroups.first(where: { $0.id == "modern-physics" })?.contains(saved) == true,
              try reopened.rows("SELECT COUNT(*) AS n FROM courses WHERE name = '현물'").first?["n"] == "1" else {
            throw DatabaseError.sqlite("빈 과목 폴더에서 추가한 PDF의 과목 저장 또는 재가져오기 검사가 실패했습니다")
        }
        print("Ravil subject folder check: nine groups, aliases, empty-folder PDF import, persistence and repeat import passed")
    }
}
