import SwiftUI

private enum SidebarDestination: Hashable {
    case section(AppModel.Section)
    case subject(String)
}

struct ContentView: View {
    @Bindable var model: AppModel
    @FocusState private var searchFocused: Bool

    private var isSearching: Bool {
        !model.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var selection: Binding<SidebarDestination?> {
        Binding {
            if isSearching { return nil }
            if model.section == .lectures || model.section == .materials {
                if let id = model.selectedSubjectGroupID { return .subject(id) }
            }
            return .section(model.section)
        } set: { destination in
            guard let destination else { return }
            model.searchQuery = ""
            switch destination {
            case .section(let section):
                model.showLibrarySection(section)
            case .subject(let id): model.showSubjectGroup(id)
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 280)
        } detail: {
            VStack(spacing: 0) {
                if !isSearching, let group = model.selectedSubjectGroup,
                   model.section == .materials || model.section == .lectures {
                    subjectHeader(group)
                    Divider()
                }
                if isSearching {
                    SearchResultsView(model: model)
                } else {
                    switch model.section {
                    case .overview: OverviewView(model: model)
                    case .lectures: LecturesView(model: model)
                    case .materials: MaterialsView(model: model)
                    case .notes: KnowledgeView(model: model)
                    case .exam: ExamView(model: model)
                    case .capture: CaptureView(model: model)
                    case .codex: CodexView(client: model.codex)
                    case .settings: PreferencesView(model: model)
                    }
                }
            }
            .navigationTitle(navigationTitle)
            .toolbar {
                if model.isImportingPDF {
                    ToolbarItem(placement: .status) {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("PDF 가져오는 중").font(.caption)
                        }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("검색", systemImage: "magnifyingglass") { searchFocused = true }
                        .keyboardShortcut("f")
                        .help("보관함 검색 ⌘F")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("새로고침", systemImage: "arrow.clockwise") { model.refresh() }
                        .disabled(model.isImportingPDF)
                        .help("새로고침")
                }
            }
        }
        .onChange(of: model.searchQuery) { _, _ in model.updateSearch() }
        .alert("Ravil", isPresented: Binding(
            get: { model.alert != nil },
            set: { if !$0 { model.alert = nil } }
        )) {
            Button("확인", role: .cancel) { model.alert = nil }
        } message: {
            Text(model.alert ?? "")
        }
    }

    private var navigationTitle: String {
        if isSearching { return "검색" }
        if model.section == .materials || model.section == .lectures,
           let group = model.selectedSubjectGroup { return group.title }
        return model.section.rawValue
    }

    private func subjectHeader(_ group: SubjectCourseGroup) -> some View {
        HStack(spacing: 16) {
            Label(group.title, systemImage: "folder")
                .font(.headline)
            Spacer(minLength: 8)
            Picker("과목 콘텐츠", selection: Binding(
                get: { model.section },
                set: { model.showSubjectContent($0) }
            )) {
                Text("자료").tag(AppModel.Section.materials)
                Text("강의").tag(AppModel.Section.lectures)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 160)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Ravil").font(.system(size: 19, weight: .semibold))
                    Spacer(minLength: 0)
                    Text(model.altFolderSnapshot?.workspaceName ?? "내 보관함")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("검색", text: $model.searchQuery)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .accessibilityLabel("강의·자료·노트 검색")
                    if !model.searchQuery.isEmpty {
                        Button("검색 지우기", systemImage: "xmark.circle.fill") { model.searchQuery = "" }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 10)

            List(selection: selection) {
                Section {
                    navigationItem(.overview)
                    navigationItem(.lectures)
                    navigationItem(.materials)
                    navigationItem(.notes)
                    navigationItem(.exam)
                }
                Section("과목") {
                    ForEach(model.subjectGroups) { group in
                        HStack(spacing: 8) {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                            Text(group.title).lineLimit(1)
                            Spacer(minLength: 0)
                            let count = model.folderItemCount(for: group)
                            if count > 0 {
                                Text(count.formatted())
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tag(SidebarDestination.subject(group.id))
                        .help(group.title)
                    }
                }
                Section {
                    navigationItem(.capture)
                    navigationItem(.codex)
                    navigationItem(.settings)
                }
            }
            .listStyle(.sidebar)
        }
    }

    private func navigationItem(_ section: AppModel.Section) -> some View {
        Label(section.rawValue, systemImage: section == .overview ? "house" : section.icon)
            .tag(SidebarDestination.section(section))
    }
}
