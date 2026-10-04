import Foundation
import AVFoundation
import ScreenCaptureKit

/// All mutable audio state, conversion and disk I/O live on one queue.
final class AudioCapturePipeline: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "ravil.audio.capture", qos: .userInitiated)
    var onLevel: ((Float, Double) -> Void)?
    var onWindow: ((URL, Int, Int) -> Void)?
    var onError: ((String) -> Void)?
    private var active = false
    private var writer: RecordingPCMWriter?
    private var timer: DispatchSourceTimer?
    private var origin = 0.0
    private var pausedAt: Double?
    private var pausedDuration = 0.0
    private var finalTime = 0.0
    private var lastWindow = 0.0
    private var level: Float = 0
    private var converters: [String: AVAudioConverter] = [:]
    private var gain: Float = 1
    private var temporaryDirectory: URL?
    private(set) var elapsed = 0.0

    private let clock: () -> Double
    init(clock: @escaping () -> Double = { CMClockGetTime(CMClockGetHostTimeClock()).seconds }) {
        self.clock = clock
        super.init()
    }
    private var now: Double { clock() }

    func prepare(url: URL, mixed: Bool, automaticFlush: Bool = true) throws {
        try queue.sync {
            writer = try RecordingPCMWriter(url: url)
            gain = mixed ? 0.5 : 1
            origin = now; pausedAt = nil; pausedDuration = 0; elapsed = 0; lastWindow = 0
            converters = [:]
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RavilLive-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            temporaryDirectory = folder
            guard automaticFlush else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer; timer.resume()
        }
    }
    func startClock() { queue.sync { origin = now; active = true } }
    func pause(_ paused: Bool) {
        queue.sync {
            if paused, pausedAt == nil { pausedAt = now }
            else if !paused, let start = pausedAt { pausedDuration += now - start; pausedAt = nil }
        }
    }
    func finish() throws -> Double {
        try queue.sync {
            timer?.cancel(); timer = nil
            let end = active ? max(0, (pausedAt ?? now) - origin - pausedDuration) : 0
            active = false
            try writer?.finish(through: Int(end * 16000))
            writer = nil; converters = [:]; elapsed = end
            return end
        }
    }
    func discardTemporaryWindows() {
        queue.async { [weak self] in
            guard let folder = self?.temporaryDirectory else { return }
            try? FileManager.default.removeItem(at: folder)
            self?.temporaryDirectory = nil
        }
    }
    func tick() {
        guard active, let writer else { return }
        elapsed = max(0, (pausedAt ?? now) - origin - pausedDuration)
        do {
            // 300 ms allows independently delivered microphone/system buffers to mix.
            try writer.flush(through: max(0, Int((elapsed - 0.3) * 16000)))
            onLevel?(pausedAt == nil ? level : 0, elapsed)
            level *= 0.6
            if pausedAt == nil, elapsed - lastWindow >= 3, let folder = temporaryDirectory {
                lastWindow = elapsed
                let url = folder.appendingPathComponent(UUID().uuidString + ".wav")
                if let range = try writer.snapshot(to: url) { onWindow?(url, range.start, range.end) }
            }
        } catch {
            timer?.cancel(); timer = nil
            onError?("녹음 파일 저장 실패: \(error.localizedDescription)")
        }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        consume(sampleBuffer, key: "mic")
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { [weak self] in
            guard let self, self.active else { return }
            self.onError?("컴퓨터 소리 수집 중단: \(error.localizedDescription)")
        }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio { consume(sampleBuffer, key: "system") }
    }
    func consume(_ sample: CMSampleBuffer, key: String) {
        guard active, pausedAt == nil, let writer, CMSampleBufferDataIsReady(sample),
              let desc = CMSampleBufferGetFormatDescription(sample),
              let format = AVAudioFormat(cmAudioFormatDescription: desc) as AVAudioFormat?,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false) else { return }
        let count = CMSampleBufferGetNumSamples(sample)
        guard count > 0, let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { return }
        input.frameLength = AVAudioFrameCount(count)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(count), into: input.mutableAudioBufferList) == noErr else { return }
        let converter: AVAudioConverter
        if let existing = converters[key], existing.inputFormat == format { converter = existing }
        else {
            guard let next = AVAudioConverter(from: format, to: target) else { return }
            converters[key] = next; converter = next
        }
        guard let result = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(count) * 16000 / format.sampleRate + 64)) else { return }
        var supplied = false
        var failure: NSError?
        let status = converter.convert(to: result, error: &failure) { _, out in
            if supplied { out.pointee = .noDataNow; return nil }
            supplied = true; out.pointee = .haveData; return input
        }
        guard status != .error, let channel = result.floatChannelData?[0] else { return }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(result.frameLength)))
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        let duration = Double(samples.count) / 16000
        let hostStart = timestamp.isFinite && abs(timestamp - now) < 10 ? timestamp : now - duration
        let start = Int(max(0, hostStart - origin - pausedDuration) * 16000)
        writer.append(samples, at: start, gain: gain)
        if !samples.isEmpty { level = max(level, sqrt(samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count))) }
    }
}
