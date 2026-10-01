import SwiftUI

struct ExamView: View {
    @Bindable var model: AppModel
    @State private var scopes: [ExamScopeItem] = []
    @State private var selectedScopeID: String?
    @State private var showCreator = false

    private var selectedScope: ExamScopeItem? {
        scopes.first { $0.id == selectedScopeID }
    }

    var body: some View {
        HSplitView {
            List(selection: $selectedScopeID) {
                ForEach(scopes) { scope in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(scope.title).fontWeight(.medium).lineLimit(1)
                        Text("자료 \(scope.materialCount)개 · 카드 \(scope.cardCount)개")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(scope.id)
                }
            }
            .frame(minWidth: 230, idealWidth: 280, maxWidth: 330)
            if let scope = selectedScope {
                ExamScopeDetailView(model: model, scope: scope, onCardsChanged: reload)
                    .id(scope.id)
                    .frame(minWidth: 380, maxWidth: .infinity)
            } else {
                ContentUnavailableView("시험 범위 없음", systemImage: "checkmark.rectangle",
                                       description: Text("시험 범위를 추가해 복습을 시작하세요."))
                    .frame(minWidth: 380, maxWidth: .infinity)
            }
        }
        .toolbar {
            Button("시험 범위 추가", systemImage: "plus") { showCreator = true }
        }
        .sheet(isPresented: $showCreator) {
            ExamScopeEditorView(model: model) { newID in
                showCreator = false
                reload()
                selectedScopeID = newID
            }
        }
        .task { reload() }
    }

    private func reload() {
        scopes = model.examScopes()
        if selectedScopeID == nil { selectedScopeID = scopes.first?.id }
    }
}

private struct ExamScopeEditorView: View {
    let model: AppModel
    let onCreated: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var includeDate = false
    @State private var examDate = Date()
    @State private var selectedIDs: Set<String> = []
    @State private var startPages: [String: Int] = [:]
    @State private var endPages: [String: Int] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("새 시험 범위").font(.title2.weight(.semibold))
            TextField("예: 2학기 중간고사", text: $title)
                .textFieldStyle(.roundedBorder)
            Toggle("시험 날짜 지정", isOn: $includeDate)
            if includeDate { DatePicker("시험 날짜", selection: $examDate, displayedComponents: .date) }
            Text("범위에 넣을 최신 PDF와 페이지를 선택하세요.")
                .font(.subheadline).foregroundStyle(.secondary)
            List {
                ForEach(model.materials) { material in
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: Binding(
                            get: { selectedIDs.contains(material.id) },
                            set: { enabled in
                                if enabled {
                                    selectedIDs.insert(material.id)
                                    startPages[material.id] = 1
                                    endPages[material.id] = material.pageCount ?? 1
                                } else {
                                    selectedIDs.remove(material.id)
                                }
                            })) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(material.title)
                                Text("\(material.course.isEmpty ? "과목 미분류" : material.course) · \(material.pageCount ?? 0)쪽")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if selectedIDs.contains(material.id) {
                            HStack {
                                Text("시작 쪽")
                                TextField("1", value: Binding(
                                    get: { startPages[material.id] ?? 1 },
                                    set: { startPages[material.id] = $0 }), format: .number)
                                    .frame(width: 55)
                                Text("끝 쪽")
                                TextField("끝", value: Binding(
                                    get: { endPages[material.id] ?? material.pageCount ?? 1 },
                                    set: { endPages[material.id] = $0 }), format: .number)
                                    .frame(width: 55)
                                Spacer()
                            }
                            .font(.caption)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            HStack {
                Button("취소") { dismiss() }
                Spacer()
                Button("범위 저장") {
                    let ranges = model.materials.filter { selectedIDs.contains($0.id) }.map { material in
                        (materialID: material.id,
                         startPage: startPages[material.id] ?? 1,
                         endPage: endPages[material.id] ?? material.pageCount ?? 1)
                    }
                    let date: String? = includeDate ? formattedDate(examDate) : nil
                    if let id = model.createExamScope(title: title, date: date, ranges: ranges) {
                        onCreated(id)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 660, height: 650)
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Seoul")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
