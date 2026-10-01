import Foundation
import AVFoundation

@MainActor
final class RecorderService {
    private var recorder: AVAudioRecorder?
    private var isStarting = false
    private(set) var startedAt: Date?
    private(set) var fileURL: URL?

    var isRecording: Bool { recorder?.isRecording ?? false }

    func start() async throws -> URL {
        guard !isStarting, recorder == nil else { throw RecorderError.alreadyRecording }
        isStarting = true
        defer { isStarting = false }
        let allowed = await AVCaptureDevice.requestAccess(for: .audio)
        guard allowed else {
            throw RecorderError.microphoneDenied
        }
        try FileManager.default.createDirectory(at: AppPaths.recordings, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: AppPaths.recordings.path)
        let url = AppPaths.recordings.appendingPathComponent("\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false
        ]
        let nextRecorder = try AVAudioRecorder(url: url, settings: settings)
        nextRecorder.isMeteringEnabled = true
        guard nextRecorder.prepareToRecord(), nextRecorder.record() else {
            throw RecorderError.startFailed
        }
        recorder = nextRecorder
        startedAt = Date()
        fileURL = url
        return url
    }

    func stop() throws -> (url: URL, startedAt: Date) {
        guard let recorder, recorder.isRecording,
              let fileURL, let startedAt else { throw RecorderError.notRecording }
        recorder.stop()
        self.recorder = nil
        self.fileURL = nil
        self.startedAt = nil
        return (fileURL, startedAt)
    }
}

enum RecorderError: LocalizedError {
    case microphoneDenied, startFailed, notRecording, alreadyRecording
    var errorDescription: String? {
        switch self {
        case .microphoneDenied: return "마이크 접근이 허용되지 않았습니다. 시스템 설정에서 Ravil에 마이크 권한을 주세요."
        case .startFailed: return "녹음을 시작할 수 없습니다. 마이크 연결을 확인해 주세요."
        case .notRecording: return "진행 중인 녹음이 없습니다."
        case .alreadyRecording: return "이미 녹음을 시작하고 있거나 진행 중입니다."
        }
    }
}
