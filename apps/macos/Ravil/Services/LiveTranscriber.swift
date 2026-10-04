import Foundation
import Observation

/// Inspired by minjun/live-translator's single-flight/latest-partial queue.
/// Full audio is saved independently; preview windows may be skipped under load.
@MainActor @Observable
final class LiveTranscriber {
    struct Window { let url: URL; let start: Int; let end: Int }
    var phrases: [RecognizedPhrase] = []
    var status = "실시간 전사 대기"
    var isRunning = false
    private var pending: Window?
    private var job: Task<Void, Never>?
    private var generation = UUID()
    private var worker: WhisperTranscriber?
    private var options = TranscriptionOptions.standard

    func start(worker: WhisperTranscriber, options: TranscriptionOptions) {
        self.worker = worker; self.options = options
        generation = UUID(); phrases = []; isRunning = true; status = "음성을 기다리는 중"
    }
    func submit(url: URL, start: Int, end: Int) {
        guard isRunning else { try? FileManager.default.removeItem(at: url); return }
        if let pending { try? FileManager.default.removeItem(at: pending.url) }
        pending = Window(url: url, start: start, end: end)
        drain()
    }
    private func drain() {
        guard job == nil, let window = pending, let baseWorker = worker else { return }
        pending = nil
        var configuredWorker = baseWorker
        configuredWorker.outputDirectory = window.url.deletingLastPathComponent()
        configuredWorker.timeout = 30
        let worker = configuredWorker
        let token = generation, options = options
        status = "전사 미리보기 생성 중"
        job = Task {
            let result = await Task.detached(priority: .utility) {
                Result { try worker.transcribe(audio: window.url, options: options) }
            }.value
            try? FileManager.default.removeItem(at: window.url)
            let prefix = window.url.deletingPathExtension().lastPathComponent + "-"
            for file in (try? FileManager.default.contentsOfDirectory(at: worker.outputDirectory, includingPropertiesForKeys: nil)) ?? [] where file.lastPathComponent.hasPrefix(prefix) {
                try? FileManager.default.removeItem(at: file)
            }
            guard self.generation == token else { self.job = nil; return }
            switch result {
            case .success(let text):
                self.phrases.removeAll { $0.offsets.to > window.start }
                self.phrases += text.compactMap { p in
                    let start = max(window.start, p.offsets.from + window.start)
                    let end = min(window.end, p.offsets.to + window.start)
                    guard end > start, !p.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                    return RecognizedPhrase(offsets: .init(from: start, to: end), text: p.text)
                }
                if self.phrases.count > 150 { self.phrases.removeFirst(self.phrases.count - 150) }
                self.status = "미리보기 · 종료 후 전체 전사로 보정"
            case .failure(let error): self.status = "미리보기 실패 · 원본 녹음은 계속 저장됨: \(error.localizedDescription)"
            }
            self.job = nil; self.drain()
        }
    }
    func waitUntilIdle() async {
        while let active = job { await active.value }
    }
    func stop() async {
        isRunning = false; generation = UUID()
        if let pending { try? FileManager.default.removeItem(at: pending.url) }; pending = nil
        await job?.value; job = nil
        status = "실시간 전사 종료"
    }
}
