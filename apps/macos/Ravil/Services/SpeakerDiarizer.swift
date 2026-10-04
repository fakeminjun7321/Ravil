import AVFoundation
import Foundation

/// Experimental acoustic clustering, not a trained speaker identity model.
/// Uses normalized spectral envelopes; labels MUST be reviewed for classroom audio.
enum SpeakerDiarizer {
    static func cluster(audio: URL, segments: [TranscriptItem], count: Int) throws -> [String: String] {
        guard (2...6).contains(count), segments.count >= count else { throw DatabaseError.sqlite("화자 수보다 많은 전사 구간이 필요합니다") }
        let file = try AVAudioFile(forReading: audio)
        let format = file.processingFormat
        let rate = format.sampleRate
        var features: [[Double]] = []
        var ids: [String] = []
        for segment in segments {
            let start = max(0, AVAudioFramePosition(Double(segment.startMilliseconds) * rate / 1000))
            let available = min(file.length - start, AVAudioFramePosition(min(2, Double(segment.endMilliseconds - segment.startMilliseconds) / 1000) * rate))
            guard available > 512 else { continue }
            file.framePosition = start
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(available)) else { continue }
            try file.read(into: buffer, frameCount: AVAudioFrameCount(available))
            guard let samples = buffer.floatChannelData?[0] else { continue }
            let data = Array(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)))
            let energy = data.reduce(0.0) { $0 + Double($1 * $1) } / Double(data.count)
            guard energy > 0.000001 else { continue }
            var spectrum = [Double](repeating: 0, count: 18)
            let stride = max(512, data.count / 8)
            for offset in Swift.stride(from: 0, through: data.count - 512, by: stride) {
                for band in spectrum.indices {
                    let frequency = 100 * pow(40, Double(band) / 17)
                    let w = 2 * Double.pi * min(frequency, rate * 0.45) / rate
                    var re = 0.0, im = 0.0
                    for n in 0..<512 {
                        let sample = Double(data[offset + n]) * (0.5 - 0.5 * cos(2 * .pi * Double(n) / 511))
                        re += sample * cos(w * Double(n)); im += sample * sin(w * Double(n))
                    }
                    spectrum[band] += log(1e-9 + re * re + im * im)
                }
            }
            let mean = spectrum.reduce(0, +) / Double(spectrum.count)
            spectrum = spectrum.map { $0 - mean }
            let norm = sqrt(spectrum.reduce(0) { $0 + $1 * $1 })
            guard norm > 0 else { continue }
            features.append(spectrum.map { $0 / norm }); ids.append(segment.id)
        }
        guard features.count >= count else { throw DatabaseError.sqlite("구분할 음성 구간이 부족합니다") }
        func distance(_ a: [Double], _ b: [Double]) -> Double { zip(a,b).reduce(0) { $0 + pow($1.0 - $1.1, 2) } }
        var centers = [features[0]]
        while centers.count < count {
            let next = features.max { a,b in centers.map { distance(a,$0) }.min()! < centers.map { distance(b,$0) }.min()! }!
            centers.append(next)
        }
        var labels = [Int](repeating: 0, count: features.count)
        for _ in 0..<20 {
            labels = features.map { f in centers.indices.min { distance(f,centers[$0]) < distance(f,centers[$1]) }! }
            for c in centers.indices {
                let members = features.indices.filter { labels[$0] == c }
                if !members.isEmpty {
                    centers[c] = features[0].indices.map { d in members.reduce(0) { $0 + features[$1][d] } / Double(members.count) }
                }
            }
        }
        return Dictionary(uniqueKeysWithValues: zip(ids, labels).map { ($0.0, "화자 후보 \($0.1 + 1)") })
    }
}
