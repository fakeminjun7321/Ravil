import Foundation
import AVFoundation

/// Serial disk writer. Audio stays bounded in memory; the WAV header is checkpointed
/// after each flush so a process interruption leaves a readable original recording.
final class RecordingPCMWriter {
    let url: URL
    let sampleRate = 16000
    private let handle: FileHandle
    private(set) var frames = 0
    private var pending: [Int: Float] = [:]
    private var recent: [Float] = []
    private var closed = false

    init(url: URL) throws {
        self.url = url
        guard FileManager.default.createFile(atPath: url.path, contents: Self.header(frames: 0), attributes: [.posixPermissions: 0o600]) else {
            throw RecorderError.startFailed
        }
        handle = try FileHandle(forUpdating: url)
        try handle.seekToEnd()
    }
    deinit { try? handle.close() }

    func append(_ samples: [Float], at frame: Int, gain: Float = 1) {
        guard !closed else { return }
        // Inputs can be delayed briefly by the OS; never rewrite committed audio.
        for (offset, value) in samples.enumerated() {
            let index = frame + offset
            if index >= frames && index < frames + sampleRate * 10 {
                pending[index, default: 0] += value.isFinite ? value * gain : 0
            }
        }
    }
    func flush(through target: Int) throws {
        guard !closed, target > frames else { return }
        guard target < Int(UInt32.max / 2) - 44 else { throw RecorderError.fileLimit }
        while frames < target {
            let end = min(target, frames + 16000)
            var bytes = Data(capacity: (end - frames) * 2)
            for index in frames..<end {
                let value = min(1, max(-1, pending.removeValue(forKey: index) ?? 0))
                recent.append(value)
                var pcm = Int16(value * 32767).littleEndian
                withUnsafeBytes(of: &pcm) { bytes.append(contentsOf: $0) }
            }
            try handle.write(contentsOf: bytes)
            frames = end
            if recent.count > sampleRate * 8 { recent.removeFirst(recent.count - sampleRate * 8) }
        }
        let end = try handle.offset()
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Self.header(frames: frames))
        try handle.seek(toOffset: end)
        try handle.synchronize()
    }
    func snapshot(to destination: URL) throws -> (start: Int, end: Int)? {
        guard recent.count >= sampleRate,
              recent.reduce(Float(0), { $0 + $1 * $1 }) / Float(recent.count) > 0.000001 else { return nil }
        let writer = try RecordingPCMWriter(url: destination)
        writer.append(recent, at: 0)
        try writer.finish(through: recent.count)
        return ((frames - recent.count) * 1000 / sampleRate, frames * 1000 / sampleRate)
    }
    func finish(through target: Int) throws {
        guard !closed else { return }
        try flush(through: target)
        try handle.close(); closed = true
    }
    static func header(frames: Int) -> Data {
        var d = Data()
        func str(_ s: String) { d.append(contentsOf: s.utf8) }
        func u16(_ n: UInt16) { var n = n.littleEndian; withUnsafeBytes(of: &n) { d.append(contentsOf: $0) } }
        func u32(_ n: UInt32) { var n = n.littleEndian; withUnsafeBytes(of: &n) { d.append(contentsOf: $0) } }
        str("RIFF"); u32(UInt32(frames * 2 + 36)); str("WAVEfmt "); u32(16)
        u16(1); u16(1); u32(16000); u32(32000); u16(2); u16(16)
        str("data"); u32(UInt32(frames * 2)); return d
    }
}
