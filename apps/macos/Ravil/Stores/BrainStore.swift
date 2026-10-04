import Foundation
import Observation

@MainActor @Observable
final class BrainStore {
    var client = CodexAppServerClient()
    var query = ""
    var question = ""
    var sources: [BrainSource] = []
    var selected: Set<String> = []
    var answers: [BrainAnswer] = []
    var searching = false
    var error: String?
    private var historyDatabase: LibraryDatabase?
    private var searchGeneration = UUID()
    private var pending: (question: String, sources: [BrainSource])?

    init() {
        client.sourceOnlyMode = true
        client.onCompletion = { [weak self] in
            guard let self else { return }
            self.complete(database: self.historyDatabase)
        }
    }
    var selectedSources: [BrainSource] { sources.filter { selected.contains($0.id) } }
    func loadHistory(database: LibraryDatabase?) {
        historyDatabase = database
        do { answers = try database?.brainAnswers() ?? [] } catch { self.error = error.localizedDescription }
    }
    func search(databaseURL: URL, lectureID: String?) {
        let token = UUID(); searchGeneration = token; searching = true
        let query = query
        Task {
            let result = await Task.detached(priority: .utility) {
                Result { try LibraryDatabase(location: databaseURL, importLegacy: false).brainSources(query: query, lectureID: lectureID) }
            }.value
            guard token == searchGeneration else { return }
            searching = false
            do { sources = try result.get(); selected = []; error = nil }
            catch { self.error = error.localizedDescription }
        }
    }
    func ask() {
        guard pending == nil, client.accountConnected, client.selectedModel != nil else { error = "먼저 Codex를 연결해 주세요"; return }
        do {
            let sources = selectedSources
            let prompt = try BrainGrounding.prompt(question: question, sources: sources)
            // Explicit user action; only the previewed excerpts are sent.
            pending = (question, sources)
            client.send(prompt)
            if !client.sending { pending = nil; error = client.errorMessage ?? "질문을 전송하지 못했습니다" }
        } catch { self.error = error.localizedDescription }
    }
    func complete(database: LibraryDatabase?) {
        guard !client.sending, let pending else { return }
        self.pending = nil
        guard client.errorMessage == nil, let response = client.messages.last(where: { $0.role == "assistant" }), !response.text.isEmpty else {
            error = client.errorMessage ?? "답변이 비어 있습니다"; return
        }
        let answer = BrainAnswer(question: pending.question, answer: response.text, sources: pending.sources, createdAt: Date())
        do {
            guard let database else { throw DatabaseError.sqlite("답변을 저장할 보관함이 없습니다") }
            try database.saveBrainAnswer(answer)
            answers.insert(answer, at: 0)
            error = BrainGrounding.warning(answer: answer.answer, sourceCount: answer.sources.count)
        } catch { self.error = "답변 저장 실패: \(error.localizedDescription)" }
    }
}
