import SwiftUI

struct ClassroomEditor: View {
    @Bindable var model: AppModel
    let lecture: LectureItem
    @State private var bookmarkNote = ""
    private var material: MaterialItem? { model.materials.first { $0.id == model.classroomMaterialID } }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Picker("수업 자료", selection: Binding(get: { model.classroomMaterialID }, set: { model.classroomMaterialID = $0; model.classroomPage = 1 })) {
                        Text("자료 선택").tag(String?.none)
                        ForEach(model.materials) { item in Text(item.title).tag(Optional(item.id)) }
                    }
                    .labelsHidden()
                    Button("PDF 추가", systemImage: "doc.badge.plus") { model.importPDFForLecture(lecture) }
                        .disabled(model.isImportingPDF)
                }
                if let material, let path = material.localPath {
                    ScrollView {
                        PDFMaterialPreview(url: URL(fileURLWithPath: path), initialPage: model.classroomPage) {
                            model.classroomPage = $0
                        }
                    }
                } else {
                    ContentUnavailableView("수업 자료", systemImage: "doc.text", description: Text("PDF를 선택하면 노트와 함께 볼 수 있어요."))
                }
            }
            .padding(16).frame(minWidth: 250, idealWidth: 450, maxWidth: .infinity, maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 0) {
                LectureNoteEditor(model: model, lecture: lecture).frame(minHeight: 150)
                Divider()
                HStack {
                    TextField("중요한 내용 메모", text: $bookmarkNote)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addBookmark)
                    Button("중요 표시", systemImage: "bookmark") { addBookmark() }
                        .keyboardShortcut("b", modifiers: [.command, .shift])
                }.padding(12)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.lectureBookmarks.filter { $0.lectureID == lecture.id }) { b in
                            BookmarkRow(model: model, bookmark: b)
                        }
                    }.padding(.horizontal, 12)
                }.frame(minHeight: 60, maxHeight: 170)
            }.frame(minWidth: 280, idealWidth: 350, maxWidth: .infinity)
        }
        .onAppear {
            if model.classroomMaterialID == nil {
                model.classroomMaterialID = model.materials.first { $0.lectureID == lecture.id }?.id
            }
        }
    }
    private func addBookmark() {
        model.addBookmark(lectureID: lecture.id, note: bookmarkNote.isEmpty ? "중요" : bookmarkNote)
        bookmarkNote = ""
    }
}

private struct BookmarkRow: View {
    @Bindable var model: AppModel
    let bookmark: LectureBookmark
    @State private var editing = false
    @State private var draft = ""
    var body: some View {
        HStack(alignment: .top) {
            Button {
                model.openBookmark(bookmark)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(TranscriptDock.clock(Double(bookmark.milliseconds) / 1000))\(bookmark.page.map { " · \($0)쪽" } ?? "")")
                        .font(.caption.monospacedDigit()).foregroundStyle(.tint)
                    Text(bookmark.note).lineLimit(3).foregroundStyle(.primary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain)
            Button("수정", systemImage: "pencil") { draft = bookmark.note; editing = true }.labelStyle(.iconOnly)
        }
        .popover(isPresented: $editing) {
            VStack {
                TextField("메모", text: $draft).textFieldStyle(.roundedBorder)
                Button("저장") { model.updateBookmark(bookmark, note: draft); editing = false }
            }.padding().frame(width: 280)
        }
    }
}

struct RecordingStatusBar: View {
    @Bindable var model: AppModel
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: model.isRecordingPaused ? "pause.circle.fill" : "record.circle.fill").foregroundStyle(.red)
            Text(model.isRecordingPaused ? "일시정지" : "녹음 중").fontWeight(.medium)
            Text(TranscriptDock.clock(model.recordingElapsed)).monospacedDigit()
            ProgressView(value: Double(min(1, model.recordingLevel * 5))).frame(width: 70)
                .accessibilityLabel("입력 음량")
            Spacer()
            Button("수업 화면") {
                if let id = model.activeLectureID { model.selectLecture(id); model.section = .capture }
            }
            Button(model.isRecordingPaused ? "계속 녹음" : "일시정지") { model.pauseRecording() }
            Button(model.isStoppingRecording ? "저장 중…" : "종료하고 전사") { model.finishRecording() }
                .disabled(model.isStoppingRecording)
        }.padding(12).background(.regularMaterial)
    }
}
