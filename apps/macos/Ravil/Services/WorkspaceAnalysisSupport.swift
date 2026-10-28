import Foundation
import CryptoKit

extension WorkspaceValue {
    var elements: [WorkspaceValue] {
        if case .array(let values) = self { return values }
        return []
    }
}

enum WorkspaceAnalysisSupport {
    static func inputDigest(_ payload: [String: WorkspaceValue]) throws -> String {
        let input: [String: WorkspaceValue] = [
            "title": .string(payload.text("title")), "body": .string(payload.text("body")),
            "format": .string(payload.text("format").isEmpty ? "plain" : payload.text("format")),
            "projectIDs": .list(payload.list("projectIDs").sorted()),
            "subjectIDs": .list(payload.list("subjectIDs").sorted())]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return SHA256.hash(data: try encoder.encode(input)).map { String(format: "%02x", $0) }.joined()
    }
    static func contextMatches(_ left: [String: WorkspaceValue], _ right: [String: WorkspaceValue]) -> Bool {
        guard let leftDigest = try? inputDigest(left), let rightDigest = try? inputDigest(right) else { return false }
        return leftDigest == rightDigest
    }
    static func invalidating(_ next: [String: WorkspaceValue], previous: [String: WorkspaceValue]?) -> [String: WorkspaceValue] {
        guard let previous, !contextMatches(previous, next),
              case .object(var analysis) = next["aiAnalysis"] else { return next }
        var payload = next
        analysis["stale"] = .bool(true); payload["aiAnalysis"] = .object(analysis)
        return payload
    }
    static func current(_ payload: [String: WorkspaceValue]) -> [String: WorkspaceValue]? {
        guard case .object(let value) = payload["aiAnalysis"], value["stale"] == .bool(false) else { return nil }
        return value
    }
}

extension PersonalWorkspace {
    @discardableResult
    func saveAnalysis(_ source: WorkspaceEntity, result: WorkspaceValue, expectedOwner: String) throws -> WorkspaceEntity {
        guard owner == expectedOwner, let current = get(source.id),
              WorkspaceAnalysisSupport.contextMatches(current.payload, source.payload) else {
            throw DatabaseError.sqlite("기록이나 계정이 바뀌었습니다. 현재 기록으로 다시 요청해 주세요.")
        }
        var analysis = result.object
        guard analysis.text("inputDigest") == (try WorkspaceAnalysisSupport.inputDigest(source.payload)) else {
            throw DatabaseError.sqlite("서버가 다른 원문을 분석했습니다. 동기화한 뒤 현재 기록으로 다시 요청해 주세요.")
        }
        let resultOwner = analysis.text("ownerID")
        guard resultOwner.isEmpty || resultOwner == owner else { throw DatabaseError.sqlite("다른 계정의 분석 결과입니다.") }
        analysis["generatedAt"] = .string(ISO8601DateFormatter().string(from: Date()))
        analysis["stale"] = .bool(false)
        var payload = current.payload
        payload["aiAnalysis"] = .object(analysis)
        return try put("record", payload, id: current.id)
    }
}
