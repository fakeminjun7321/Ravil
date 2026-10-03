import SwiftUI

struct TranscriptDock: View {
    @Bindable var model: AppModel
    let lecture: LectureItem
    @State private var editing: TranscriptItem?
    @State private var speakerCount = 2
    @State private var showSpeakers = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("전사 · \(model.transcript.count)개 구간")
                    .font(.headline)
                Spacer()
                Button("화자 구분") { showSpeakers = true }
                    .disabled(model.transcript.count < 2 || lecture.audioPath == nil || model.isSeparatingSpeakers || model.isRecording)
                if model.isSeparatingSpeakers { ProgressView().controlSize(.small) }
                if model.isTranscribing { ProgressView().controlSize(.small) }
                if lecture.audioPath != nil {
                    Button(model.isPlaying ? "일시정지" : "재생",
                           systemImage: model.isPlaying ? "pause.fill" : "play.fill") {
                        model.togglePlayback()
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.isRecording)
                    Text(Self.clock(model.playbackPosition))
                        .font(.system(.caption, design: .monospaced))
                    Slider(value: Binding(
                        get: { min(model.playbackPosition, max(model.playbackDuration, 1)) },
                        set: { model.seekPlayback(to: $0) }
                    ), in: 0...max(model.playbackDuration, 1))
                    .frame(maxWidth: 170)
                    .disabled(model.playbackDuration <= 0)
                    Text(Self.clock(model.playbackDuration))
                        .font(.system(.caption, design: .monospaced))
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        if model.transcript.isEmpty {
                            Text("전사 결과가 아직 없습니다.")
                                .foregroundStyle(.secondary)
                                .padding(18)
                        }
                        ForEach(model.transcript) { segment in
                            Button {
                                model.play(at: segment.startMilliseconds)
                            } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    Text(segment.clock)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.tint)
                                        .frame(width: 70, alignment: .leading)
                                    VStack(alignment: .leading, spacing: 2) {
                                        if let speaker = segment.speaker {
                                            Text(speaker).font(.caption.weight(.semibold))
                                                .foregroundStyle(.secondary)
                                        }
                                        Text(segment.text).foregroundStyle(.primary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                                .padding(.horizontal, 18)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(model.isRecording)
                            .contextMenu {
                                Button("전사·화자 수정") { editing = segment }
                                Button("이 시각 중요 표시") {
                                    model.playbackPosition = Double(segment.startMilliseconds) / 1000
                                    model.addBookmark(lectureID: lecture.id, note: String(segment.text.prefix(100)))
                                }
                            }
                            .id(segment.id)
                        }
                    }
                }
                .task(id: model.jumpTargetSegmentID) {
                    guard let id = model.jumpTargetSegmentID else { return }
                    await Task.yield()
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
        .background(.regularMaterial)
        .sheet(item: $editing) { segment in TranscriptEditSheet(model: model, segment: segment, lectureID: lecture.id) }
        .popover(isPresented: $showSpeakers) {
            VStack(alignment: .leading, spacing: 12) {
                Text("실험적 화자 후보 구분").font(.headline)
                Text("목소리의 음향 특징으로 구간을 묶습니다. 선생님·학생을 확정하지 않으며 잡음이나 말투에 따라 틀릴 수 있습니다. 전사에서 화자를 검토·수정하세요.").font(.caption)
                Stepper("예상 화자 수: \(speakerCount)", value: $speakerCount, in: 2...6)
                Button("후보 만들기") { model.separateSpeakers(lecture: lecture, count: speakerCount); showSpeakers = false }
            }.padding().frame(width: 310)
        }
    }

    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let value = Int(seconds)
        if value >= 3_600 {
            return String(format: "%d:%02d:%02d", value / 3_600, value / 60 % 60, value % 60)
        }
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}

private struct TranscriptEditSheet: View {
    @Bindable var model: AppModel
    let segment: TranscriptItem
    let lectureID: String
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var speaker = ""
    @State private var renameAll = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("전사 수정 · \(segment.clock)").font(.headline)
            TextEditor(text: $text).frame(height: 150)
            TextField("화자 이름", text: $speaker).textFieldStyle(.roundedBorder)
            if segment.speaker != nil { Toggle("이 강의의 같은 화자 이름도 변경", isOn: $renameAll) }
            Text("녹음 시각과 수정 전 기록은 보존됩니다.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("취소") { dismiss() }
                Spacer()
                Button("저장") {
                    if renameAll, let old = segment.speaker { model.renameSpeaker(old, to: speaker, lectureID: lectureID) }
                    model.editTranscript(segment, text: text, speaker: speaker)
                    dismiss()
                }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 500)
        .onAppear { text = segment.text; speaker = segment.speaker ?? "" }
    }
}
