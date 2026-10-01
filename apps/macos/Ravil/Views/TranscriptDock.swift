import SwiftUI

struct TranscriptDock: View {
    @Bindable var model: AppModel
    let lecture: LectureItem

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("전사 · \(model.transcript.count)개 구간")
                    .font(.headline)
                Spacer()
                if model.isTranscribing { ProgressView().controlSize(.small) }
                if lecture.audioPath != nil {
                    Button(model.isPlaying ? "일시정지" : "재생",
                           systemImage: model.isPlaying ? "pause.fill" : "play.fill") {
                        model.togglePlayback()
                    }
                    .buttonStyle(.borderless)
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
