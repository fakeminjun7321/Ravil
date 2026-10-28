import Foundation

@main
struct WorkspacePlanCheck {
    struct Failure: Error {let message: String}
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() {throw Failure(message: message)}
    }
    static func main() throws {
        let reference = ISO8601DateFormatter().date(from: "2026-10-19T00:00:00Z")!
        let personal = WorkspacePlanParser.parse("## 10.20 계획\n사진집\n- 인쇄 견적 확인\n- [ ] 표지 수정\n10.21 일상\n[x] 예약 확인\n산책 2회", referenceDate: reference)
        try require(personal.warnings.isEmpty, "Personal plan produced warnings")
        try require(personal.tasks.count == 4, "Personal actions were lost")
        try require(personal.tasks.map(\.day) == ["2026-10-20", "2026-10-20", "2026-10-21", "2026-10-21"], "Dates changed")
        try require(personal.tasks.map(\.topic) == ["사진집", "사진집", "일상", "일상"], "Topics changed")
        try require(personal.tasks.map(\.action) == ["인쇄 견적 확인", "표지 수정", "예약 확인", "산책"], "Checkbox markers or actions changed")
        try require(personal.tasks.last?.repetitions == 2, "Repetitions changed")
        let invalid = WorkspacePlanParser.parse("2026-02-30\n- 연락하기", referenceDate: reference)
        try require(invalid.tasks.first?.day == "" && invalid.warnings.count == 1, "Invalid date silently normalized")
        let previous = WorkspacePlanParser.parse("10.14\n광학 (1) 학습지 정독 2회", referenceDate: reference).tasks[0]
        let updated = WorkspacePlanParser.parse("10.14\n광학\n(1) 학습지 정독 3회", referenceDate: reference).tasks[0]
        try require(previous.id(recordID: "source") == updated.id(recordID: "source"), "Formatting changed task identity")
        if CommandLine.arguments.count > 1 {
            let fixture = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
            let legacy = WorkspacePlanParser.parse(fixture, referenceDate: reference)
            try require(legacy.tasks.count == 22 && legacy.tasks.reduce(0) {$0 + $1.repetitions} == 25, "Existing study plan was not preserved")
        }
        print("Workspace plan parser: personal actions, Markdown/checkboxes, dates, repetitions and legacy task identity passed.")
    }
}
