import SwiftUI
import PDFKit

struct LectureDetailView: View {
    private enum MainTab: String, CaseIterable, Identifiable {
        case note = "노트"
        case summary = "요약"
        var id: String { rawValue }
    }

    @Bindable var model: AppModel
    let lecture: LectureItem
    @State private var tab: MainTab = .note
    @State private var showTranscriptionOptions = false

    var body: some View {
        VStack(spacing: 0) {
            header

            if lecture.altNoteType == "slide" {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        AltSlideSourceView(source: model.altSlideSource)
                        LectureNoteEditor(model: model, lecture: lecture)
                            .id(lecture.id)
                            .frame(minHeight: 280)
                    }
                    .frame(maxWidth: 850, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            } else {
                Divider()

                VSplitView {
                    Group {
                        switch tab {
                        case .note:
                            LectureNoteEditor(model: model, lecture: lecture)
                                .id(lecture.id)
                        case .summary:
                            LectureSummaryView(model: model, lecture: lecture)
                        }
                    }
                    .frame(minHeight: 220, maxHeight: .infinity)

                    TranscriptDock(model: model, lecture: lecture)
                        .frame(minHeight: 165, idealHeight: 230, maxHeight: 420)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $showTranscriptionOptions) {
            TranscriptionOptionsSheet(model: model, lecture: lecture)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(lecture.title)
                    .font(.system(size: 22, weight: .semibold))
                    .lineLimit(2)
                    .textSelection(.enabled)
                Text("\(lecture.displaySubjectName) · \(lecture.date)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 10) {
                if lecture.altNoteType != "slide" {
                    Picker("강의 내용", selection: $tab) {
                        ForEach(MainTab.allCases) { tab in Text(tab.rawValue).tag(tab) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 150)
                }
                Spacer(minLength: 10)
                if lecture.altNoteType != "slide" && lecture.canTranscribe && lecture.audioPath != nil {
                    Button(lecture.status == "recorded" ? "전사 시작" : "다시 전사",
                           systemImage: "text.bubble") {
                        showTranscriptionOptions = true
                    }
                    .disabled(model.isTranscribing || !model.modelReady)
                }
                Button("PDF 연결", systemImage: "doc.badge.plus") {
                    model.importPDFForLecture(lecture)
                }
            }
            .controlSize(.small)
            .labelStyle(.titleOnly)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }
}

private struct LectureNoteEditor: View {
    let model: AppModel
    let lecture: LectureItem
    @State private var draft: String

    init(model: AppModel, lecture: LectureItem) {
        self.model = model
        self.lecture = lecture
        _draft = State(initialValue: model.lectureMemoText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let imported = model.providerSummary, !imported.isEmpty {
                DisclosureGroup("Alt에서 가져온 노트") {
                    ScrollView {
                        Text(imported)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)
                    }
                    .frame(maxHeight: 140)
                }
                .font(.subheadline)
            }
            HStack {
                Text("내 노트").font(.headline)
                Spacer()
                Text("자동 저장").font(.caption).foregroundStyle(.secondary)
            }
            TextEditor(text: $draft)
                .font(.body)
                .frame(minHeight: 130)
                .scrollContentBackground(.hidden)
                .lineSpacing(5)
                .onChange(of: draft) { _, newValue in
                    model.saveLectureMemo(newValue, for: lecture.id)
                }
        }
        .padding(24)
    }
}

private struct AltSlideSourceView: View {
    let source: AltSlideSource?

    private var readablePDF: URL? {
        guard let path = source?.localPDFPath,
              path.lowercased().hasSuffix(".pdf"),
              FileManager.default.fileExists(atPath: path) else { return nil }
        let url = URL(fileURLWithPath: path)
        guard let document = PDFDocument(url: url), document.pageCount > 0,
              !document.isEncrypted else { return nil }
        return url
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("슬라이드").font(.headline)
            if let url = readablePDF {
                PDFMaterialPreview(url: url)
            } else if let source,
                      !source.extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("원본 PDF 없음 · 추출된 텍스트")
                    .font(.caption).foregroundStyle(.secondary)
                Text(source.extractedText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .lineSpacing(5)
            } else {
                ContentUnavailableView("슬라이드가 없습니다", systemImage: "doc.text.image")
                    .frame(maxWidth: .infinity, minHeight: 260)
            }
        }
        .padding(24)
    }
}

private struct LectureSummaryView: View {
    let model: AppModel
    let lecture: LectureItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if let intelligence = model.intelligence {
                    if intelligence.verification?.sourceChanged == true {
                        Label("원문 변경됨 · 이전 분석을 다시 확인하세요",
                              systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    } else {
                        SummaryTextCard(text: intelligence.summary.text,
                                        isMissing: intelligence.summary.status == "missing")
                        SpeakerBreakdown(segments: model.transcript)
                        if !intelligence.studyPriorities.isEmpty {
                            VStack(alignment: .leading, spacing: 9) {
                                Text("복습 우선순위 후보").font(.headline)
                                ForEach(intelligence.studyPriorities.prefix(6)) { item in
                                    HStack {
                                        Text(item.concept)
                                        Spacer()
                                        Text(item.level).font(.caption.bold())
                                            .foregroundStyle(item.level == "HIGH" ? Color.orange : Color.secondary)
                                    }
                                }
                            }
                        }
                        CandidateSection(title: "교수 강조 후보", items: intelligence.professorEmphasis, model: model)
                        CandidateSection(title: "시험 언급 후보", items: intelligence.examMentions, model: model)
                        CandidateSection(title: "과제 후보", items: intelligence.assignments, model: model)
                    }
                } else if let summary = model.providerSummary {
                    SummaryTextCard(text: summary, isMissing: false)
                    SpeakerBreakdown(segments: model.transcript)
                } else {
                    ContentUnavailableView("요약이 아직 없습니다", systemImage: "text.alignleft")
                }

                let directlyLinked = model.materials.filter { $0.lectureID == lecture.id }
                if !directlyLinked.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("연결된 자료").font(.headline)
                        ForEach(directlyLinked) { material in
                            Button(material.title, systemImage: "doc.text") { model.showMaterial(material) }
                                .buttonStyle(.link)
                                .multilineTextAlignment(.leading)
                        }
                    }
                }

                let sameCourse = model.materials.filter {
                    $0.lectureID != lecture.id && lecture.courseID != nil && $0.courseID == lecture.courseID
                }
                if !sameCourse.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("같은 과목 자료").font(.headline)
                        ForEach(sameCourse) { material in
                            Button(material.title, systemImage: "doc.text") { model.showMaterial(material) }
                                .buttonStyle(.link)
                                .multilineTextAlignment(.leading)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 800, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct SummaryTextCard: View {
    let text: String
    let isMissing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("강의 요약").font(.headline)
                Spacer()
                if !isMissing {
                    Text("Alt · 검토 전")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(isMissing ? "요약이 아직 없습니다." : text)
                .foregroundStyle(isMissing ? .secondary : .primary)
                .lineSpacing(5)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SpeakerBreakdown: View {
    private struct SpeakerStat: Identifiable {
        var id: String { name }
        let name: String
        let duration: Int
    }

    let segments: [TranscriptItem]
    private var speakers: [SpeakerStat] {
        let grouped = Dictionary(grouping: segments.filter { $0.speaker != nil }, by: { $0.speaker ?? "" })
        return grouped.map { name, lines in
            SpeakerStat(name: name, duration: lines.reduce(0) { $0 + max(0, $1.endMilliseconds - $1.startMilliseconds) })
        }.sorted { $0.duration > $1.duration }
    }

    var body: some View {
        if !speakers.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("화자").font(.headline)
                    Spacer()
                    Text("전사 길이 기준 추정")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                let total = max(1, speakers.reduce(0) { $0 + $1.duration })
                ForEach(speakers) { speaker in
                    HStack(spacing: 11) {
                        Text(speaker.name)
                            .frame(width: 90, alignment: .leading)
                            .lineLimit(1)
                            .help(speaker.name)
                        ProgressView(value: Double(speaker.duration), total: Double(total))
                            .tint(.secondary)
                        Text("\(Int(Double(speaker.duration) / Double(total) * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 38, alignment: .trailing)
                    }
                }
            }
        }
    }
}

private struct CandidateSection: View {
    let title: String
    let items: [IntelligenceCandidate]
    let model: AppModel

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.headline)
                    .padding(.bottom, 6)
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    HStack(alignment: .top, spacing: 12) {
                        if let milliseconds = item.evidence?.startMs {
                            Button(TranscriptDock.clock(Double(milliseconds) / 1_000)) {
                                model.play(at: milliseconds)
                            }
                            .font(.system(.caption, design: .monospaced))
                            .buttonStyle(.link)
                            .frame(width: 58, alignment: .leading)
                        }
                        Text(item.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineSpacing(4)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 10)
                    if index < items.count - 1 { Divider() }
                }
            }
        }
    }
}
