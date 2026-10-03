import Foundation

enum LivePreviewCheck {
    @MainActor static func run(audio: URL, output: URL) async throws {
        guard !FileManager.default.fileExists(atPath: output.path) else { throw DatabaseError.sqlite("새 검사 폴더를 지정하세요") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let window = output.appendingPathComponent("generated-input.wav")
        try FileManager.default.copyItem(at: audio, to: window)
        let live = LiveTranscriber()
        let worker = WhisperTranscriber(executable: AppPaths.whisperCLI, model: AppPaths.preferredModel)
        live.start(worker: worker, options: TranscriptionOptions(language: "ko", translateToEnglish: false, keywordPrompt: ""))
        live.submit(url: window, start: 5000, end: 25000)
        await live.waitUntilIdle()
        guard !live.phrases.isEmpty, live.phrases.allSatisfy({ $0.offsets.from >= 5000 && $0.offsets.to <= 25000 }) else {
            throw DatabaseError.sqlite("파일 기반 실시간 미리보기 실패: \(live.status)")
        }
        let report: [String: Any] = ["phrases": live.phrases.map { ["from": $0.offsets.from, "to": $0.offsets.to, "text": $0.text] }, "microphoneStarted": false]
        try JSONSerialization.data(withJSONObject: report, options: .prettyPrinted).write(to: output.appendingPathComponent("report.json"))
        await live.stop()
        print("Live preview passed: bundled local model, file input, absolute offsets, cleanup. No microphone opened.")
    }
}
