import SwiftUI

struct OverviewView: View {
    let model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack(alignment: .firstTextBaseline) {
                    Text("최근 기록")
                        .font(.system(size: 24, weight: .semibold))
                    Spacer()
                    Menu {
                        Button("PDF 가져오기", systemImage: "doc.badge.plus") {
                            model.importPDFViaOpenPanel(courseID: nil)
                        }
                        Button("녹음 파일 가져오기", systemImage: "waveform.badge.plus") {
                            model.importAudioViaOpenPanel(courseID: nil)
                        }
                        Divider()
                        Button("새 노트", systemImage: "square.and.pencil") {
                            model.section = .notes
                            model.selectedNoteID = nil
                        }
                    } label: {
                        Label("추가", systemImage: "plus")
                    }
                    .fixedSize()
                }

                recentLectures
                recentMaterials
                subjects
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { recordingBar }
    }

    private var recentLectures: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading("강의") { model.showCourse(nil) }
            if model.lectures.isEmpty {
                emptyRow("아직 강의가 없습니다", icon: "waveform")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.lectures.prefix(5).enumerated()), id: \.element.id) { index, lecture in
                        Button { model.selectLecture(lecture.id) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: lecture.symbol)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(lecture.title).fontWeight(.medium).lineLimit(1)
                                    if let subject = lecture.subjectName {
                                        Text(subject).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 12)
                                Text(lecture.date)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(LibraryRowButtonStyle())
                        .help(lecture.title)
                        if index < min(model.lectures.count, 5) - 1 {
                            Divider().padding(.leading, 44)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var recentMaterials: some View {
        if !model.materials.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeading("자료") { model.showLibrarySection(.materials) }
                VStack(spacing: 0) {
                    ForEach(Array(model.materials.prefix(3).enumerated()), id: \.element.id) { index, material in
                        Button {
                            model.showMaterial(material)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "doc.text")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 22)
                                Text(material.title).fontWeight(.medium).lineLimit(1)
                                Spacer(minLength: 12)
                                if let pages = material.pageCount {
                                    Text("\(pages)쪽").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(LibraryRowButtonStyle())
                        .help(material.title)
                        if index < min(model.materials.count, 3) - 1 {
                            Divider().padding(.leading, 44)
                        }
                    }
                }
            }
        }
    }

    private var subjects: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("과목").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 16)], spacing: 4) {
                ForEach(model.subjectGroups) { group in
                    Button { model.showSubjectGroup(group.id) } label: {
                        HStack(spacing: 9) {
                            Image(systemName: "folder").foregroundStyle(.secondary)
                            Text(group.title).lineLimit(1)
                            Spacer(minLength: 4)
                            let count = model.folderItemCount(for: group)
                            if count > 0 {
                                Text(count.formatted())
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(LibraryRowButtonStyle())
                    .accessibilityLabel("\(group.title) 과목 열기")
                }
            }
        }
    }

    private func sectionHeading(_ title: String, action: @escaping () -> Void) -> some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            Button("전체 보기", action: action)
                .font(.caption)
                .buttonStyle(.link)
        }
    }

    private func emptyRow(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 24)
            .padding(.horizontal, 10)
    }

    private var recordingBar: some View {
        HStack(spacing: 10) {
            Image(systemName: model.isRecording ? "record.circle.fill" : "mic")
                .foregroundStyle(model.isRecording ? Color.red : Color.secondary)
            Text(model.isRecording ? "녹음 중" : "새 강의 녹음")
                .fontWeight(.medium)
            if model.isRecording {
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    let elapsed = max(0, Int(timeline.date.timeIntervalSince(model.recordingStartedAt ?? timeline.date)))
                    Text(String(format: "%02d:%02d", elapsed / 60, elapsed % 60))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(model.isRecording ? "녹음 화면" : "녹음 시작") {
                model.section = .capture
                if !model.isRecording { model.beginRecording() }
            }
            .disabled(model.isStartingRecording || model.isTranscribing)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 13)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
