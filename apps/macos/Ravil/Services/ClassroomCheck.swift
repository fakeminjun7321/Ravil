import Foundation
import AVFoundation
import PDFKit
import SwiftUI
import AppKit

enum ClassroomCheck {
    @MainActor static func run(folder: URL) async throws {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw DatabaseError.sqlite("Classroom check: " + message) }
        }
        guard !FileManager.default.fileExists(atPath: folder.path) else { throw DatabaseError.sqlite("새 검사 경로를 지정하세요") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let wav = folder.appendingPathComponent("generated.wav")
        let writer = try RecordingPCMWriter(url: wav)
        for second in 0..<8 {
            let hz = second < 4 ? 180.0 : 720.0
            let signal = (0..<16000).map { Float(sin(Double($0) * 2 * .pi * hz / 16000) * 0.5) }
            writer.append(signal, at: second * 16000)
            try writer.flush(through: (second + 1) * 16000)
        }
        // Header is readable even before a normal close (crash recovery checkpoint).
        try require(try AVAudioFile(forReading: wav).length == 128000, "checkpoint WAV length")
        let snapshot = folder.appendingPathComponent("window.wav")
        let range = try writer.snapshot(to: snapshot)
        try require(range?.start == 0 && range?.end == 8000, "preview window offsets")
        try writer.finish(through: 128000)
        let mixture = folder.appendingPathComponent("mix.wav")
        let mix = try RecordingPCMWriter(url: mixture)
        mix.append([Float](repeating: 0.8, count: 1600), at: 0, gain: 0.5)
        mix.append([Float](repeating: 0.4, count: 1600), at: 0, gain: 0.5)
        try mix.finish(through: 3200)
        let file = try AVAudioFile(forReading: mixture)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 3200)!
        try file.read(into: buffer)
        try require(abs(buffer.floatChannelData![0][0] - 0.6) < 0.001 && buffer.floatChannelData![0][2000] == 0, "mixing and missing-input silence")

        let dbURL = folder.appendingPathComponent("library.sqlite")
        let db = try LibraryDatabase(location: dbURL, importLegacy: false)
        let id = try db.addRecording(title: "에너지 수업", courseID: nil, audioURL: wav, startedAt: Date())
        let phrases = (0..<8).map { RecognizedPhrase(offsets: .init(from: $0*1000, to: ($0+1)*1000), text: "에너지 설명 \($0)") }
        try db.saveTranscript(phrases, for: id)
        try db.saveMemo("에너지 보존과 조건을 비교한다", for: id)
        let pdfURL = folder.appendingPathComponent("handout.pdf")
        try LectureExporter.pdf("에너지 보존 학습지\nE = mc²\n한국어와 English", to: pdfURL)
        let material = try db.importLocalPDF(from: pdfURL, courseID: nil, lectureID: id, subjectName: nil)
        let bookmark = LectureBookmark(lectureID: id, milliseconds: 2315, materialID: material.id, page: 1, note: "중요한 조건")
        try db.saveBookmark(bookmark)
        let original = try db.transcript(for: id)[0]
        try db.editTranscript(segmentID: original.id, text: "에너지 정정된 설명", speaker: "선생님")
        try db.renameSpeaker(lectureID: id, old: "선생님", new: "교수")
        let reopened = try LibraryDatabase(location: dbURL, importLegacy: false)
        let updated = try reopened.transcript(for: id)
        try require(updated[0].startMilliseconds == original.startMilliseconds && updated[0].text == "에너지 정정된 설명" && updated[0].speaker == "교수", "transcript edit persistence")
        try require(try reopened.rows("SELECT * FROM transcript_edits WHERE segment_id = ?", values: [original.id]).count == 2, "edit history")
        try require(try reopened.bookmarks(for: id) == [bookmark], "bookmark source/page/time persistence")
        var rejected = false
        do { try db.saveBookmark(LectureBookmark(lectureID: id, milliseconds: -1, materialID: nil, page: nil, note: "bad")) }
        catch { rejected = true }
        try require(rejected, "negative bookmark rejected")
        let sources = try reopened.brainSources(query: "에너지")
        try require(Set(sources.map(\.kind)).isSuperset(of: ["transcript", "material", "lecture"]), "cross-document retrieval")
        let chosen = [sources.first { $0.kind == "transcript" }!, sources.first { $0.kind == "material" }!]
        let prompt = try BrainGrounding.prompt(question: "에너지 설명의 공통점은?", sources: chosen)
        try require(prompt.contains("[1]") && prompt.contains("[2]") && prompt.count < 16000, "bounded evidence prompt")
        try require(BrainGrounding.warning(answer: "설명 [9]", sourceCount: 2) != nil, "invalid citations flagged")
        let answer = BrainAnswer(question: "에너지 비교", answer: "두 자료의 에너지 설명을 비교합니다 [1] [2]", sources: chosen, createdAt: Date())
        try db.saveBrainAnswer(answer)
        try require(try reopened.brainAnswers().first?.sources == chosen, "answer evidence snapshot persists")
        for format in [LectureExportFormat.markdown, .srt, .vtt, .pdf] {
            let value = LectureExporter.text(title: "수업", memo: "한글 노트", segments: updated, bookmarks: [bookmark], format: format)
            let url = folder.appendingPathComponent("export." + format.suffix)
            if format == .pdf {
                try LectureExporter.pdf(value, to: url)
                try require(PDFDocument(url: url)?.string?.contains("한글 노트") == true, "PDF Korean extraction")
            } else { try value.write(to: url, atomically: true, encoding: .utf8) }
            if format == .srt { try require(value.contains("00:00:00,000 --> 00:00:01,000"), "SRT timestamps") }
            if format == .vtt { try require(value.hasPrefix("WEBVTT\n") && value.contains("00:00:01.000"), "VTT timestamps") }
        }
        let labels = try SpeakerDiarizer.cluster(audio: wav, segments: updated, count: 2)
        try require(Set(labels.values).count == 2 && labels.count == 8, "synthetic acoustic cluster separation (not voice accuracy)")
        // Re-transcription retains edited historical segments and bookmark/source pointers.
        try db.saveTranscript([RecognizedPhrase(offsets: .init(from: 0, to: 8000), text: "새 전사")], for: id)
        try require(try db.rows("SELECT text FROM transcript_segments WHERE id = ?", values: [original.id]).first?["text"] == "에너지 정정된 설명", "edited history preserved on re-transcription")
        try require(try db.bookmarks(for: id) == [bookmark], "bookmark survives re-transcription")
        try AudioPipelineCheck.run(folder: folder)
        let report: [String: Any] = ["resamplingAndPause": true, "pcmCheckpoint": true, "mixAndSilence": true, "previewOffsets": true,
            "bookmarkPersistence": true, "transcriptHistory": true, "crossSourceRetrieval": true,
            "answerEvidencePersistence": true, "exportMarkdownPDFSRTVTT": true, "syntheticAcousticClusters": true,
            "microphoneStarted": false, "systemCaptureStarted": false, "liveAIServiceCalled": false]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("report.json"))
        print("Classroom check passed: generated audio/PDF, local DB, exports, citations. No microphone or system capture was started.")
    }
}
