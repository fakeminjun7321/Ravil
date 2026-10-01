import SwiftUI

struct KnowledgeView: View {
    private enum SuppressedSelection: Equatable {
        case id(String)
        case none

        init(_ id: String?) { self = id.map(Self.id) ?? .none }
    }

    @Bindable var model: AppModel
    @State private var draftTitle = ""
    @State private var draftBody = ""
    @State private var editingNoteID: String?
    @State private var loadedTitle = ""
    @State private var loadedBody = ""
    @State private var suppressedSelection: SuppressedSelection?
    @State private var showingRecoveredDraft = false

    var body: some View {
        HSplitView {
            List(selection: $model.selectedNoteID) {
                ForEach(model.notes) { note in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(note.title.isEmpty ? "제목 없음" : note.title).lineLimit(1)
                        Text(note.body).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .tag(note.id)
                }
            }
            .frame(minWidth: 220, idealWidth: 260, maxWidth: 310)
            .toolbar {
                Button("새 노트", systemImage: "square.and.pencil") {
                    guard saveDraftIfNeeded() else { return }
                    showingRecoveredDraft = false
                    model.selectedNoteID = nil
                    loadSelected()
                }
            }
            VStack(alignment: .leading, spacing: 16) {
                if let recovery = model.unsavedNoteDraft {
                    if showingRecoveredDraft {
                        Label("복구된 초안 · 저장 필요", systemImage: "arrow.uturn.backward.circle")
                            .font(.caption).foregroundStyle(.orange)
                    } else {
                        Button("저장되지 않은 초안 열기", systemImage: "arrow.uturn.backward.circle") {
                            guard saveDraftIfNeeded() else { return }
                            openRecoveredDraft(recovery)
                        }
                    }
                }
                TextField("제목", text: $draftTitle)
                    .font(.system(size: 24, weight: .semibold))
                    .textFieldStyle(.plain)
                Divider()
                TextEditor(text: $draftBody)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(.vertical, 6)
                HStack {
                    if draftTitle != loadedTitle || draftBody != loadedBody {
                        Text("저장되지 않음").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("저장") {
                        if let id = model.saveNote(id: editingNoteID, title: draftTitle, body: draftBody,
                                                   resolvesRecoveredDraft: showingRecoveredDraft) {
                            editingNoteID = id
                            loadedTitle = draftTitle
                            loadedBody = draftBody
                            showingRecoveredDraft = false
                        } else {
                            showingRecoveredDraft = true
                        }
                    }
                    .keyboardShortcut("s")
                    .disabled(draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              && draftBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(28)
            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            let requestedNoteID = model.requestedNoteIDFromSearch
            model.requestedNoteIDFromSearch = nil
            if let requestedNoteID, requestedNoteID == model.selectedNoteID {
                loadSelected()
            } else if let recovery = model.unsavedNoteDraft {
                openRecoveredDraft(recovery)
            } else {
                loadSelected()
            }
        }
        .onChange(of: model.selectedNoteID) { _, _ in
            if suppressedSelection == SuppressedSelection(model.selectedNoteID) {
                suppressedSelection = nil
                return
            }
            suppressedSelection = nil
            guard saveDraftIfNeeded() else {
                suppressedSelection = SuppressedSelection(editingNoteID)
                model.selectedNoteID = editingNoteID
                return
            }
            showingRecoveredDraft = false
            loadSelected()
        }
        .onDisappear { _ = saveDraftIfNeeded() }
    }

    private func loadSelected() {
        editingNoteID = model.selectedNoteID
        draftTitle = model.selectedNote?.title ?? ""
        draftBody = model.selectedNote?.body ?? ""
        loadedTitle = draftTitle
        loadedBody = draftBody
    }

    private func saveDraftIfNeeded() -> Bool {
        if showingRecoveredDraft {
            return model.preserveUnsavedNoteDraft(id: editingNoteID, title: draftTitle, body: draftBody)
        }
        guard draftTitle != loadedTitle || draftBody != loadedBody else { return true }
        if editingNoteID == nil && draftTitle.isEmpty && draftBody.isEmpty { return true }
        guard let id = model.saveNote(id: editingNoteID, title: draftTitle, body: draftBody,
                                      selectAfterSave: false) else {
            showingRecoveredDraft = true
            return false
        }
        editingNoteID = id
        loadedTitle = draftTitle
        loadedBody = draftBody
        return true
    }

    private func openRecoveredDraft(_ recovery: UnsavedNoteDraft) {
        let saved = model.notes.first { $0.id == recovery.id }
        let targetSelection = saved?.id
        if model.selectedNoteID != targetSelection {
            suppressedSelection = SuppressedSelection(targetSelection)
            model.selectedNoteID = targetSelection
        }
        editingNoteID = recovery.id
        loadedTitle = saved?.title ?? ""
        loadedBody = saved?.body ?? ""
        draftTitle = recovery.title
        draftBody = recovery.body
        showingRecoveredDraft = true
    }
}
