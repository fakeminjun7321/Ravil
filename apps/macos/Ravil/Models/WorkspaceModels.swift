import Foundation
import CryptoKit

enum WorkspaceValue: Codable, Equatable {
    case string(String), number(Double), bool(Bool), object([String: WorkspaceValue]), array([WorkspaceValue]), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: WorkspaceValue].self) { self = .object(v) }
        else { self = .array(try c.decode([WorkspaceValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    var string: String { if case .string(let value) = self { return value }; return "" }
    var integer: Int { if case .number(let value) = self { return Int(value) }; return 0 }
    var strings: [String] { if case .array(let values) = self { return values.map(\.string) }; return [] }
    var object: [String: WorkspaceValue] { if case .object(let value) = self { return value }; return [:] }
    static func list(_ values: [String]) -> WorkspaceValue { .array(values.map { .string($0) }) }
}
extension Dictionary where Key == String, Value == WorkspaceValue {
    func text(_ key: String) -> String { self[key]?.string ?? "" }
    func int(_ key: String, default fallback: Int = 0) -> Int { self[key] == nil ? fallback : self[key]!.integer }
    func list(_ key: String) -> [String] { self[key]?.strings ?? [] }
}
struct WorkspaceEntity: Codable, Identifiable, Equatable {
    var id: String
    var kind: String
    var payload: [String: WorkspaceValue]
    var revision: Int = 0
    var deleted = false
    var updatedAt: String
    var pending: Bool?
    var remoteJSON: String?
    var title: String { payload.text("title") }
}
struct WorkspaceTaskDraft: Equatable {
    var topic: String
    var action: String
    var day: String
    var repetitions: Int
    var minutes = 30
    func id(recordID: String) -> String {
        let digest = SHA256.hash(data: Data([recordID, day, topic, action].joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }.joined()
        let indices = [8, 12, 16, 20, 32]
        var start = 0
        return indices.map { end in defer { start = end }; return String(digest.dropFirst(start).prefix(end - start)) }.joined(separator: "-")
    }
    var payload: [String: WorkspaceValue] {
        ["topic": .string(topic), "action": .string(action), "day": .string(day),
         "repetitions": .number(Double(repetitions)), "minutes": .number(Double(minutes))]
    }
}
enum WorkspacePlanParser {
    static func parse(_ body: String, referenceDate: Date = Date()) -> (tasks: [WorkspaceTaskDraft], warnings: [String]) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let year = calendar.component(.year, from: referenceDate)
        let text = body.replacingOccurrences(of: "&#x20;", with: " ").replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: #"\((\d+)\)"#, with: "\n($1)", options: .regularExpression)
        let dateRE = try! NSRegularExpression(pattern: #"^(?:\d+[.)]\s+)?(?:(\d{4})[-/.])?(\d{1,2})[./-](\d{1,2})(?:\s*(?:일|\([^)]*\)))?(?:\s+(.+))?\s*$"#)
        let actionRE = try! NSRegularExpression(pattern: #"풀기|정독|공부|리딩|재점검|암기|읽기|보기|하기|작성|정리|복습|검토|확인|연락|예약|보내기|준비|구매|수정|제출|운동|산책|회\s*$"#)
        let repeatRE = try! NSRegularExpression(pattern: #"(\d+)\s*회"#)
        var day = "", topic = ""
        var tasks: [WorkspaceTaskDraft] = [], warnings: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: #"^#{1,6}\s+"#, with: "", options: .regularExpression)
            if line.isEmpty { continue }
            let range = NSRange(line.startIndex..., in: line)
            func captured(_ match: NSTextCheckingResult, _ group: Int) -> String {
                guard let r = Range(match.range(at: group), in: line) else { return "" }
                return String(line[r])
            }
            if let date = dateRE.firstMatch(in: line, range: range) {
                let y = Int(captured(date, 1)) ?? year, m = Int(captured(date, 2))!, d = Int(captured(date, 3))!
                let components = DateComponents(year: y, month: m, day: d)
                if let value = calendar.date(from: components), calendar.component(.year, from: value) == y,
                   calendar.component(.month, from: value) == m, calendar.component(.day, from: value) == d {
                    day = String(format: "%04d-%02d-%02d", y, m, d)
                } else { warnings.append("날짜 확인: \(line)"); day = "" }
                let heading = captured(date, 4).trimmingCharacters(in: .whitespaces)
                topic = heading.range(of: #"^(?:공부할\s*것|공부\s*계획|계획|할\s*일)$"#, options: .regularExpression) != nil ? "" : heading
                continue
            }
            let numbered = line.range(of: #"^(?:\(\d+\)|\d+[.)]|[-*]|\[[ xX]\])\s*"#, options: .regularExpression) != nil
            if !numbered && actionRE.firstMatch(in: line, range: range) == nil {
                topic = line.replacingOccurrences(of: #"^#+\s*"#, with: "", options: .regularExpression); continue
            }
            let repetitions = repeatRE.firstMatch(in: line, range: range).flatMap { Int(captured($0, 1)) } ?? 1
            guard (1...99).contains(repetitions) else { warnings.append("횟수 확인: \(line)"); continue }
            let action = line.replacingOccurrences(of: #"^(?:\(\d+\)|\d+[.)]|[-*]|\[[ xX]\])\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"^\[[ xX]\]\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s*\d+\s*회\s*$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if !action.isEmpty { tasks.append(WorkspaceTaskDraft(topic: topic, action: action, day: day, repetitions: repetitions)) }
        }
        return (tasks, warnings)
    }
}
