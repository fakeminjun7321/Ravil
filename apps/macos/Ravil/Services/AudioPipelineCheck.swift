import AVFoundation
import Foundation

enum AudioPipelineCheck {
    static func buffer(time: Double, frequency: Double = 400) throws -> CMSampleBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
        let samples = (0..<4800).map { Float(0.4 * sin(Double($0) * 2 * .pi * frequency / 48000)) }
        let bytes = samples.withUnsafeBytes { Data($0) }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: bytes.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: bytes.count, flags: 0, blockBufferOut: &block) == noErr, let block else { throw RecorderError.startFailed }
        _ = bytes.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count) }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000), presentationTimeStamp: CMTime(seconds: time, preferredTimescale: 48000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: format.formatDescription, sampleCount: 4800, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample) == noErr,
            let sample else { throw RecorderError.startFailed }
        return sample
    }
    static func run(folder: URL) throws {
        var clock = 1000.0
        let pipeline = AudioCapturePipeline(clock: { clock })
        let url = folder.appendingPathComponent("pipeline.wav")
        try pipeline.prepare(url: url, mixed: true, automaticFlush: false)
        pipeline.startClock()
        for index in 0..<10 {
            clock = 1000 + Double(index) / 10
            let mic = try buffer(time: clock), system = try buffer(time: clock, frequency: 800)
            pipeline.queue.sync { pipeline.consume(mic, key: "mic"); pipeline.consume(system, key: "system"); pipeline.tick() }
        }
        clock = 1001; pipeline.pause(true)
        clock = 1006
        let paused = try buffer(time: clock)
        pipeline.queue.sync { pipeline.consume(paused, key: "mic"); pipeline.tick() }
        pipeline.pause(false)
        for index in 0..<10 {
            clock = 1006 + Double(index) / 10
            let sample = try buffer(time: clock)
            pipeline.queue.sync { pipeline.consume(sample, key: "mic"); pipeline.tick() }
        }
        clock = 1007
        let elapsed = try pipeline.finish()
        pipeline.discardTemporaryWindows()
        let file = try AVAudioFile(forReading: url)
        guard file.length == 32000, abs(elapsed - 2) < 0.001 else { throw DatabaseError.sqlite("일시정지 시간 제외 또는 16kHz 변환 실패") }
        let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 32000)!
        try file.read(into: pcm)
        let data = Array(UnsafeBufferPointer(start: pcm.floatChannelData![0], count: Int(pcm.frameLength)))
        let first = data[1000..<14000].reduce(Float(0)) { $0 + abs($1) }
        let second = data[17000..<30000].reduce(Float(0)) { $0 + abs($1) }
        guard first > 100, second > 100 else { throw DatabaseError.sqlite("변환된 신호가 저장되지 않았습니다") }
        print("Audio pipeline passed: generated 48kHz buffers → 16kHz mix, 5-second pause excluded. No capture device opened.")
    }
}
