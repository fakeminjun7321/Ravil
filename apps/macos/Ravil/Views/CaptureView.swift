import SwiftUI

struct CaptureView: View {
    @Bindable var model: AppModel

    private var transcriptionOptionsTitle: String {
        var parts = ["전사 옵션"]
        if model.translateTranscription { parts.append("영어 번역") }
        if !model.keywordPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("키워드 설정됨")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        if model.isRecording, let lecture = model.lectures.first(where: { $0.id == model.activeLectureID }) {
            VStack(spacing: 0) {
                Text(lecture.title).font(.title2).frame(maxWidth: .infinity, alignment: .leading).padding(16)
                ClassroomEditor(model: model, lecture: lecture)
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.live.status).font(.caption).foregroundStyle(.secondary)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(model.live.phrases.enumerated()), id: \.offset) { _, phrase in
                                Text("[\(TranscriptDock.clock(Double(phrase.offsets.from) / 1000))] \(phrase.text)")
                                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                            }
                        }
                    }
                }.padding(14).frame(height: 180)
            }
        } else { setup }
    }

    private var setup: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text("새 강의 녹음")
                        .font(.system(size: 24, weight: .semibold))
                    Spacer()
                    Button("파일 가져오기", systemImage: "waveform.badge.plus") {
                        model.importAudioViaOpenPanel(courseID: model.recordingCourseID)
                    }
                    .disabled(model.isTranscribing || model.isStartingRecording || model.isRecording)
                }

                VStack(alignment: .leading, spacing: 16) {
                    TextField("강의 제목", text: $model.recordingTitle)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                    Picker("과목", selection: $model.recordingCourseID) {
                        Text("나중에 분류").tag(String?.none)
                        ForEach(model.courses) { course in
                            Text(course.name).tag(Optional(course.id))
                        }
                    }
                    Picker("녹음할 소리", selection: $model.recordingInput) {
                        ForEach(RecordingInput.allCases) { input in Text(input.rawValue).tag(input) }
                    }
                    if model.recordingInput != .system {
                        Picker("마이크", selection: $model.recordingDeviceID) {
                            Text("기본 마이크").tag(String?.none)
                            ForEach(RecorderService.devices()) { device in Text(device.name).tag(Optional(device.id)) }
                        }
                    }
                    if model.recordingInput != .microphone {
                        Text("컴퓨터 소리 수집에는 macOS 화면 및 오디오 기록 권한이 필요합니다. 화면 영상은 저장하지 않습니다.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("녹음 중 전사 미리보기", isOn: $model.livePreviewEnabled)
                    Picker("언어", selection: $model.transcriptionLanguage) {
                        Text("자동 감지").tag("auto")
                        Text("한국어").tag("ko")
                        Text("영어").tag("en")
                        Text("일본어").tag("ja")
                        Text("중국어").tag("zh")
                    }
                }
                .frame(maxWidth: 460, alignment: .leading)

                DisclosureGroup(transcriptionOptionsTitle) {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("영어로 번역", isOn: $model.translateTranscription)
                        TextField("키워드 (쉼표로 구분)", text: $model.keywordPrompt, axis: .vertical)
                            .lineLimit(2...4)
                            .textFieldStyle(.roundedBorder)
                            .help("예: 오일러 방법, PIV, 경계조건")
                    }
                    .padding(.top, 10)
                }

                Divider()

                VStack(alignment: .leading, spacing: 16) {
                    if model.isRecording {
                        HStack(spacing: 12) {
                            Label("녹음 중", systemImage: "record.circle.fill")
                                .foregroundStyle(.red)
                            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                                let elapsed = max(0, Int(timeline.date.timeIntervalSince(model.recordingStartedAt ?? timeline.date)))
                                Text(String(format: "%02d:%02d:%02d", elapsed / 3_600, (elapsed / 60) % 60, elapsed % 60))
                                    .font(.system(size: 28, weight: .medium, design: .monospaced))
                            }
                        }
                        Button("종료하고 전사", systemImage: "stop.fill") { model.finishRecording() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                    } else {
                        Button("녹음 시작", systemImage: "mic.fill") { model.beginRecording() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .disabled(model.isTranscribing || model.isStartingRecording)
                        if model.isStartingRecording { ProgressView("마이크 준비 중…") }
                    }
                    if model.isTranscribing { ProgressView("전사 중…") }
                }

                if !model.modelReady {
                    Label("전사 모델을 찾을 수 없습니다. 설정에서 경로를 확인하세요.", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }

                if !model.recoverableRecordings.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        Text("저장되지 않은 녹음").font(.headline)
                        Text("남아 있는 오디오를 강의 목록에 등록할 수 있습니다.")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(model.recoverableRecordings) { pending in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(pending.title.isEmpty ? "복구된 녹음" : pending.title).fontWeight(.medium)
                                Text(pending.url.path)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                Button("강의 목록에 등록", systemImage: "arrow.clockwise") {
                                    model.retryRecordingRegistration(pending.id)
                                }
                                .disabled(model.isTranscribing)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onChange(of: model.transcriptionLanguage) { _, _ in model.saveTranscriptionPreferences() }
        .onChange(of: model.translateTranscription) { _, _ in model.saveTranscriptionPreferences() }
        .onChange(of: model.keywordPrompt) { _, _ in model.saveTranscriptionPreferences() }
    }
}
