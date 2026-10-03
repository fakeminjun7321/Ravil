import Foundation

enum BrainIntegrationCheck {
    @MainActor static func run(folder: URL) async throws {
        guard !FileManager.default.fileExists(atPath: folder.path) else { throw DatabaseError.sqlite("새 검사 폴더를 지정하세요") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let db = try LibraryDatabase(location: folder.appendingPathComponent("test.sqlite"), importLegacy: false)
        let store = BrainStore()
        store.loadHistory(database: db)
        store.client.connect()
        defer { store.client.disconnect() }
        let limit = Date().addingTimeInterval(25)
        while store.client.selectedModel == nil && Date() < limit {
            if let error = store.client.errorMessage { throw DatabaseError.sqlite(error) }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        guard store.client.accountConnected, store.client.selectedModel != nil else { throw DatabaseError.sqlite("Codex 연결 또는 로그인 확인 실패") }
        store.sources = [
            BrainSource(id: "generated-a", kind: "note", targetID: "test-a", title: "생성한 실험 기록 A", text: "실험 A에서 구슬 3개의 질량은 각각 2g이었다. 총 질량은 6g이었다.", milliseconds: nil, page: nil),
            BrainSource(id: "generated-b", kind: "note", targetID: "test-b", title: "생성한 실험 기록 B", text: "같은 구슬 3개를 다시 측정했더니 총 질량이 7g이었다. 저울은 영점 조절을 하지 않았다.", milliseconds: nil, page: nil)
        ]
        store.selected = Set(store.sources.map(\.id))
        store.question = "두 기록의 차이는 무엇이며 원인으로 무엇을 의심할 수 있나? 근거 번호를 넣어 3문장 이내로 답해줘."
        store.ask()
        let deadline = Date().addingTimeInterval(90)
        while store.client.sending && Date() < deadline { try await Task.sleep(nanoseconds: 200_000_000) }
        guard !store.client.sending else { throw DatabaseError.sqlite("AI 답변 제한 시간 초과") }
        store.complete(database: db)
        guard let answer = try db.brainAnswers().first,
              Set(BrainGrounding.citations(in: answer.answer)).isSuperset(of: [1,2]) else {
            throw DatabaseError.sqlite(store.error ?? "두 자료의 근거를 포함한 답변 저장이 확인되지 않았습니다")
        }
        let reopened = try LibraryDatabase(location: db.location, importLegacy: false)
        guard try reopened.brainAnswers().first?.id == answer.id else { throw DatabaseError.sqlite("AI 답변 재열기 실패") }
        try JSONEncoder().encode(answer).write(to: folder.appendingPathComponent("generated-answer.json"))
        print("Brain integration passed: one live request, two generated sources, grounded answer saved and reopened. No private library data sent.")
    }
}
