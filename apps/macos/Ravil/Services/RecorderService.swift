import Foundation
import AVFoundation
import ScreenCaptureKit

struct RecordingDevice: Identifiable, Hashable { let id: String; let name: String }
enum RecordingInput: String, CaseIterable, Identifiable {
    case microphone = "마이크", system = "컴퓨터 소리", mixed = "마이크 + 컴퓨터 소리"
    var id: String { rawValue }
}

@MainActor
final class RecorderService {
    private var runtimeObserver: NSObjectProtocol?
    private var session: AVCaptureSession?
    private var stream: SCStream?
    private var isStarting = false
    let pipeline = AudioCapturePipeline()
    private(set) var startedAt: Date?
    private(set) var fileURL: URL?
    private(set) var isRecording = false
    private(set) var isPaused = false

    static func devices() -> [RecordingDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
            .map { RecordingDevice(id: $0.uniqueID, name: $0.localizedName) }
    }
    func start(input: RecordingInput = .microphone, deviceID: String? = nil) async throws -> URL {
        guard !isStarting, !isRecording else { throw RecorderError.alreadyRecording }
        isStarting = true
        defer { isStarting = false }
        if input != .system {
            guard await AVCaptureDevice.requestAccess(for: .audio) else { throw RecorderError.microphoneDenied }
        }
        try FileManager.default.createDirectory(at: AppPaths.recordings, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = AppPaths.recordings.appendingPathComponent(UUID().uuidString + ".wav")
        try pipeline.prepare(url: url, mixed: input == .mixed)
        do {
            if input != .microphone {
                let available = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = available.displays.first else { throw RecorderError.noDisplay }
                let config = SCStreamConfiguration()
                config.capturesAudio = true; config.excludesCurrentProcessAudio = true
                config.sampleRate = 48000; config.channelCount = 2
                config.width = 2; config.height = 2; config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                let next = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: pipeline)
                try next.addStreamOutput(pipeline, type: .audio, sampleHandlerQueue: pipeline.queue)
                try await next.startCapture(); stream = next
            }
            if input != .system {
                let device = deviceID.flatMap { AVCaptureDevice(uniqueID: $0) } ?? AVCaptureDevice.default(for: .audio)
                guard let device else { throw RecorderError.startFailed }
                let next = AVCaptureSession()
                let source = try AVCaptureDeviceInput(device: device)
                let output = AVCaptureAudioDataOutput()
                guard next.canAddInput(source), next.canAddOutput(output) else { throw RecorderError.startFailed }
                next.addInput(source); next.addOutput(output)
                output.setSampleBufferDelegate(pipeline, queue: pipeline.queue)
                // Start/stop may block; do not run them on the UI actor.
                await Task.detached { next.startRunning() }.value
                guard next.isRunning else { throw RecorderError.startFailed }
                session = next
                runtimeObserver = NotificationCenter.default.addObserver(forName: .AVCaptureSessionRuntimeError, object: next, queue: nil) { [weak pipeline] _ in
                    pipeline?.onError?("마이크 장치에서 오류가 발생했습니다. 녹음 파일을 보존하고 종료합니다.")
                }
            }
            pipeline.startClock()
            startedAt = Date(); fileURL = url; isRecording = true; isPaused = false
            return url
        } catch {
            if let stream { try? await stream.stopCapture() }; stream = nil
            if let session { await Task.detached { session.stopRunning() }.value }; session = nil
            _ = try? pipeline.finish()
            pipeline.discardTemporaryWindows()
            throw error
        }
    }
    func setPaused(_ paused: Bool) {
        guard isRecording else { return }
        pipeline.pause(paused); isPaused = paused
    }
    func stop() async throws -> (url: URL, startedAt: Date) {
        guard isRecording, let fileURL, let startedAt else { throw RecorderError.notRecording }
        if let observer = runtimeObserver { NotificationCenter.default.removeObserver(observer); runtimeObserver = nil }
        if let session { await Task.detached { session.stopRunning() }.value }; session = nil
        if let stream { try? await stream.stopCapture() }; stream = nil
        isRecording = false; isPaused = false
        defer { self.fileURL = nil; self.startedAt = nil }
        _ = try pipeline.finish()
        return (fileURL, startedAt)
    }
}

enum RecorderError: LocalizedError {
    case microphoneDenied, startFailed, notRecording, alreadyRecording, noDisplay, fileLimit
    var errorDescription: String? {
        switch self {
        case .microphoneDenied: return "마이크 접근이 허용되지 않았습니다. 시스템 설정에서 Ravil에 마이크 권한을 주세요."
        case .startFailed: return "녹음을 시작할 수 없습니다. 입력 장치를 확인해 주세요."
        case .notRecording: return "진행 중인 녹음이 없습니다."
        case .alreadyRecording: return "이미 녹음을 시작하고 있거나 진행 중입니다."
        case .noDisplay: return "컴퓨터 소리를 수집할 디스플레이를 찾을 수 없습니다."
        case .fileLimit: return "WAV 저장 한도에 도달했습니다. 녹음을 종료해 주세요."
        }
    }
}
