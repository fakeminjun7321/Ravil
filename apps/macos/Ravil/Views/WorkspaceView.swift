import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct WorkspaceView: View {
    @Bindable var workspace: PersonalWorkspace
    let google: GoogleDriveAccount
    let codex: CodexAppServerClient
    let localModel: LocalModelClient
    init(workspace: PersonalWorkspace, google: GoogleDriveAccount, codex: CodexAppServerClient? = nil,
         localModel: LocalModelClient? = nil, initialTab: String = "records") {
        self.workspace = workspace; self.google = google
        self.codex = codex ?? CodexAppServerClient(); self.localModel = localModel ?? LocalModelClient()
        self.initialTab = initialTab
    }
    @State private var assistantRecord: WorkspaceEntity?
    @State private var assistantOwner = ""
    @State private var analyzing = false
    var initialTab = "records"
    @State private var tab = "records"
    @State private var title = ""
    @State private var text = ""
    @State private var editingID: String?
    @State private var editingRevision = 0
    @State private var subjectID = ""
    @State private var projectID = ""
    @State private var search = ""
    @State private var accountSheet = false
    @State private var contextSheet = false
    @State private var contextKind = "subject"
    @State private var contextTitle = ""
    @State private var contextProjectKind = "project"
    @State private var examDate = Date()
    @State private var notice: String?
    @State private var receipts: [String: String] = [:]
    @State private var autosave: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("내 작업", selection: $tab) {
                    Text("기록").tag("records"); Text("계획").tag("plan")
                    Text("나에 대해").tag("profile"); Text("프로젝트와 백업").tag("projects")
                }.pickerStyle(.segmented).frame(maxWidth: 420)
                Spacer()
                Text(workspace.status).font(.caption).foregroundStyle(.secondary)
                Button("동기화", systemImage: "arrow.triangle.2.circlepath") { Task { await workspace.sync() } }
                    .disabled(!workspace.isConnected || workspace.isSyncing)
                Button("계정", systemImage: "person.crop.circle") { accountSheet = true }
            }.padding(16)
            Divider()
            if workspace.items("project").contains(where: {
                $0.payload.text("phase") != "archived" && !$0.payload.text("examDate").isEmpty &&
                $0.payload.text("examDate") < String(ISO8601DateFormatter().string(from: Date()).prefix(10))
            }), tab != "projects" {
                HStack { Text("종료일이 지난 프로젝트가 있어요. 백업과 보관을 확인해 주세요."); Spacer(); Button("정리하기") { tab = "projects" } }
                    .padding(12).background(.quaternary)
            }
            switch tab {
            case "plan": plans
            case "profile": profile
            case "projects": projects
            default: records
            }
        }
        .onAppear { tab = initialTab; if let e = workspace.get(workspace.selectedRecordID) { load(e) } }
        .onChange(of: initialTab) { _, value in tab = value }
        .onChange(of: workspace.selectedRecordID) { _, id in if let e = workspace.get(id), id != editingID { load(e) } }
        .onChange(of: workspace.owner) { _, _ in assistantRecord = nil; codex.disconnect(); localModel.disconnect(); newRecord(); subjectID = ""; projectID = "" }
        .onChange(of: workspace.entities) { _, _ in
            if let current = workspace.get(editingID), current.payload.text("body") == text,
               current.title == title || (title.isEmpty && current.title == String((text.components(separatedBy: .newlines).first { !$0.isEmpty } ?? "").prefix(70))) { editingRevision = current.revision }
        }
        .onChange(of: text) { _, _ in queueSave() }
        .onChange(of: title) { _, _ in queueSave() }
        .sheet(isPresented: $accountSheet) { WorkspaceAccountSheet(workspace: workspace) }
        .sheet(isPresented: $contextSheet) { contextEditor }
        .sheet(item: $assistantRecord) { source in
            RecordAssistantSheet(codex: codex, local: localModel, title: source.title,
                bodyText: source.payload.text("body"), recordID: source.id) { answer in
                do {
                    guard workspace.owner == assistantOwner, let current = workspace.get(source.id),
                          WorkspaceAnalysisSupport.contextMatches(current.payload, source.payload) else {
                        throw DatabaseError.sqlite("원문이나 계정이 바뀌었습니다. 현재 기록으로 다시 요청해 주세요.")
                    }
                    _ = try workspace.put("record", ["title": .string("AI 메모 · " + source.title), "body": .string(answer),
                        "kind": .string("note"), "subjectIDs": source.payload["subjectIDs"] ?? .list([]),
                        "projectIDs": source.payload["projectIDs"] ?? .list([]), "fileIDs": .list([]), "tags": .list([]),
                        "sourceRecordIDs": .list([source.id]), "aiGenerated": .bool(true),
                        "createdAt": .string(ISO8601DateFormatter().string(from: Date()))])
                    assistantRecord = nil; Task { await workspace.sync() }
                } catch { assistantRecord = nil; notice = error.localizedDescription }
            }
        }
        .alert("RAVIL", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("확인") { notice = nil }
        } message: { Text(notice ?? "") }
    }
    private var records: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text("내 기록").font(.headline); Spacer(); Button("새 기록", systemImage: "plus") { newRecord() }.labelStyle(.iconOnly) }
                TextField("기록 · 주제 · 프로젝트 검색", text: $search).textFieldStyle(.roundedBorder)
                List(selection: $workspace.selectedRecordID) {
                    ForEach(search.isEmpty ? workspace.records : workspace.search(search)) { e in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(e.title).lineLimit(2)
                            Text(e.payload.text("kind") == "plan" ? "계획" : "메모").font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 5).tag(e.id)
                    }
                }.listStyle(.plain)
                HStack {
                    Button("주제 추가") { contextKind = "subject"; contextSheet = true }
                    Button("프로젝트 추가") { contextKind = "project"; contextSheet = true }
                }
            }.padding(16).frame(minWidth: 190, idealWidth: 230, maxWidth: 280)
            document.frame(minWidth: 420)
        }
    }
    private var document: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                TextField("제목 없이 바로 적어도 돼요", text: $title).font(.system(size: 25, weight: .semibold)).textFieldStyle(.plain)
                HStack {
                    Picker("주제", selection: $subjectID) {
                        Text("주제 연결").tag("")
                        ForEach(workspace.items("subject")) { Text($0.title).tag($0.id) }
                    }.frame(maxWidth: 200)
                    Picker("프로젝트", selection: $projectID) {
                        Text("연결 없음").tag("")
                        ForEach(workspace.items("project").filter { $0.payload.text("phase") != "archived" }) { Text($0.title).tag($0.id) }
                    }.frame(maxWidth: 220)
                }
                TextEditor(text: $text).font(.system(size: 15)).scrollContentBackground(.hidden).frame(height: 380)
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty { Text("생각과 경험, 아이디어를 편하게 남겨보세요.\n주제와 프로젝트는 나중에 연결해도 돼요.")
                            .foregroundStyle(.tertiary).padding(.top, 4).padding(.leading, 5).allowsHitTesting(false) }
                    }
                HStack {
                    Button("저장") { commit() }.keyboardShortcut(.return, modifiers: .command)
                    Button("계획으로 정리") { organize() }
                    Menu("AI 도움") {
                        Button("Codex · 로컬 모델") { do { if let source = try save() { assistantOwner = workspace.owner; assistantRecord = source } } catch { notice = error.localizedDescription } }
                        Button("RAVIL AI로 정리") { analyze() }.disabled(!workspace.isConnected || analyzing)
                    }.fixedSize().disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("파일 연결") { attach() }.disabled(!workspace.isConnected)
                }
                Text("원문 하나를 주제와 프로젝트에서 함께 봅니다.").font(.caption).foregroundStyle(.secondary)
                if let e = workspace.get(editingID) {
                    if let remote = e.remoteJSON {
                        Divider(); Text("다른 기기에서도 수정한 기록입니다.").font(.headline)
                        if let other = try? JSONDecoder().decode(WorkspaceEntity.self, from: Data(remote.utf8)) { Text(other.payload.text("body")).textSelection(.enabled) }
                        HStack {
                            Button("다른 기기 수정 사용") { resolve(e.id, keepCopy: false) }
                            Button("내 수정도 별도로 남기기") { resolve(e.id, keepCopy: true) }
                        }
                    }
                    RecordAnalysisView(record: e, entities: workspace.entities, busy: analyzing,
                        open: { id in do { _ = try save(); if let next = workspace.get(id) { load(next) } } catch { notice = error.localizedDescription } },
                        ask: { analyze(question: $0) },
                        addTask: { action, evidence in do {
                            guard let fresh = try save(), fresh.id == e.id,
                                  WorkspaceAnalysisSupport.current(fresh.payload) != nil else { throw DatabaseError.sqlite("현재 기록으로 다시 분석해 주세요.") }
                            if !workspace.items("task").contains(where: { $0.payload.text("recordID") == e.id && $0.payload.text("action") == action && $0.payload.list("evidenceIDs") == evidence }) {
                                _ = try workspace.put("task", ["recordID": .string(e.id), "action": .string(action), "topic": .string(""),
                                    "day": .string(""), "repetitions": .number(1), "completed": .number(0), "minutes": .number(30),
                                    "subjectIDs": e.payload["subjectIDs"] ?? .list([]), "evidenceIDs": .list(evidence)])
                            }
                            Task { await workspace.sync() }
                        } catch { notice = error.localizedDescription } },
                        applyTags: { tags in do {
                            guard let fresh = try save(), fresh.id == e.id,
                                  WorkspaceAnalysisSupport.current(fresh.payload) != nil else { throw DatabaseError.sqlite("현재 기록으로 다시 분석해 주세요.") }
                            var payload = fresh.payload; payload["tags"] = .list(Array(Set(payload.list("tags") + tags)).sorted())
                            _ = try workspace.put("record", payload, id: e.id); Task { await workspace.sync() }
                        } catch { notice = error.localizedDescription } })
                    let tasks = workspace.items("task").filter { $0.payload.text("recordID") == e.id }
                    if !tasks.isEmpty { Divider(); Text("이 기록에서 나온 할 일").font(.headline); ForEach(tasks) { taskRow($0) } }
                    ForEach(e.payload.list("parseWarnings"), id: \.self) { Text($0).foregroundStyle(.orange) }
                }
            }.padding(32).frame(maxWidth: 980, alignment: .leading)
        }
        .onChange(of: subjectID) { _, _ in queueSave() }
        .onChange(of: projectID) { _, _ in queueSave() }
    }
    private var plans: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("계획").font(.largeTitle.weight(.semibold))
                Text("날짜와 반복 횟수를 보존합니다. 시간은 예상값이며 바꿀 수 있어요.").foregroundStyle(.secondary)
                HStack {
                    Button("Google Calendar 연결") { connectCalendar() }.disabled(!workspace.isConnected || google.isConnecting)
                    Button("캘린더에 배치") {
                        Task { do {
                            await workspace.sync()
                            let (value, _) = try await workspace.request("calendar/sync", body: .object([:]))
                            notice = "새 일정 \(value.object.int("created"))개 · 수정 \(value.object.int("updated"))개"
                        } catch { notice = error.localizedDescription } }
                    }.disabled(!workspace.isConnected)
                }
                Text("Mac에서 한 번 Google Calendar 권한을 연결하면 웹·PWA에서도 사용합니다.").font(.caption).foregroundStyle(.secondary)
                Toggle("계획 저장 시 캘린더 자동 배치", isOn: Binding(get: {
                    workspace.items("preference").first { $0.payload.text("key") == "planner" }?.payload["autoCalendar"] == .bool(true)
                }, set: { enabled in
                    let old = workspace.items("preference").first { $0.payload.text("key") == "planner" }
                    var p = old?.payload ?? ["key": .string("planner"), "startHour": .number(19), "endHour": .number(23), "breakMinutes": .number(5)]
                    p["autoCalendar"] = .bool(enabled)
                    do { _ = try workspace.put("preference", p, id: old?.id ?? UUID().uuidString.lowercased()); Task { await workspace.sync() } } catch { notice = error.localizedDescription }
                })).disabled(!workspace.isConnected)
                ForEach(workspace.items("task").sorted { $0.payload.text("day") < $1.payload.text("day") }) { taskRow($0) }
                if workspace.items("task").isEmpty { Text("기록의 체크리스트와 계획을 할 일로 정리할 수 있어요. 날짜는 나중에 정해도 됩니다.").foregroundStyle(.secondary) }
            }.padding(32).frame(maxWidth: 1100, alignment: .leading)
        }
    }
    private func taskRow(_ task: WorkspaceEntity) -> some View {
        HStack(spacing: 10) {
            Button {
                do { try workspace.complete(task); Task { await workspace.sync() } } catch { notice = error.localizedDescription }
            } label: { Image(systemName: task.payload.int("completed") >= task.payload.int("repetitions") ? "checkmark.square.fill" : "square").font(.title3) }
                .buttonStyle(.plain).accessibilityLabel("할 일 1회 완료 또는 완료 취소")
            VStack(alignment: .leading, spacing: 4) {
                Text([task.payload.text("topic"), task.payload.text("action")].filter { !$0.isEmpty }.joined(separator: " · "))
                Text(task.payload.text("day").isEmpty ? "날짜 미정" : task.payload.text("day")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(task.payload.int("completed"))/\(task.payload.int("repetitions"))").monospacedDigit().foregroundStyle(.secondary)
            Stepper("\(task.payload.int("minutes"))분", value: Binding(get: { task.payload.int("minutes") }, set: { value in
                var p = task.payload; p["minutes"] = .number(Double(value))
                do { _ = try workspace.put("task", p, id: task.id) } catch { notice = error.localizedDescription }
            }), in: 5...180, step: 5).fixedSize()
            Button(workspace.studyingTaskID == task.id ? "작업 마침" : "작업 시작") { do { try workspace.toggleStudy(task) } catch { notice = error.localizedDescription } }
            Button("원문") { if let e = workspace.get(task.payload.text("recordID")) { load(e); tab = "records" } }
        }.padding(.vertical, 12).overlay(alignment: .bottom) { Divider() }
    }
    private var profile: some View {
        let studies = workspace.items("observation").filter { $0.payload.text("event") == "study" && $0.payload.int("minutes") > 0 }
        let groups = Dictionary(grouping: studies, by: { $0.payload.text("action") })
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("나에 대해").font(.largeTitle.weight(.semibold))
                Text("RAVIL 안의 활동 \(workspace.items("observation").count)개를 연결했습니다.").foregroundStyle(.secondary)
                ForEach(groups.keys.sorted(), id: \.self) { action in
                    let events = groups[action]!, times = events.map { $0.payload.int("minutes") }.sorted()
                    Text(action).font(.headline)
                    Text("\(times[times.count / 2])분 · \(events.count)회 기록 · \(events.count >= 3 ? "추정" : "기록 부족")")
                    HStack { ForEach(Array(events.prefix(3))) { e in Button("근거 기록") { if let source = workspace.get(e.payload.text("recordID")) { load(source); tab = "records" } } } }
                    Divider()
                }
                if studies.isEmpty { Text("작업 시작·마침으로 RAVIL 안의 활동 시간을 기록합니다. 활동이 쌓이면 시간 배분에 반영할 수 있어요.").foregroundStyle(.secondary) }
                Text("내가 알려준 정정").font(.headline)
                ForEach(workspace.items("preference").filter { $0.payload.text("key") == "correction" }) { e in
                    HStack { Text(e.payload.text("text")); Spacer(); Button("잊기") { do { _ = try workspace.put("preference", e.payload, id: e.id, deleted: true) } catch { notice = error.localizedDescription } } }
                }
                TextField("잘못 파악한 점이나 기억할 내용", text: $contextTitle)
                Button("반영하기") { do {
                    _ = try workspace.put("preference", ["key": .string("correction"), "text": .string(contextTitle)])
                    contextTitle = ""; Task { await workspace.sync() }
                } catch { notice = error.localizedDescription } }.disabled(contextTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(32).frame(maxWidth: 850, alignment: .leading)
        }
    }
    private var projects: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("프로젝트와 백업").font(.largeTitle.weight(.semibold))
                Text("끝난 프로젝트는 백업을 확인한 뒤 보관합니다. 원문 기록은 계속 남아 있어요.").foregroundStyle(.secondary)
                Button("프로젝트 추가") { contextKind = "project"; contextSheet = true }
                ForEach(workspace.items("project").filter { $0.payload.text("phase") != "archived" }) { project in
                    Text(project.title).font(.title2.weight(.semibold))
                    Text(project.payload.text("examDate")).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("기록 보기") { workspace.selectedProjectID = project.id; workspace.selectedSubjectID = ""; tab = "records" }
                        Button("백업 파일 받기") { exportBackup(project) }.disabled(!workspace.isConnected)
                        Button("백업 검사") { verifyBackup(project) }.disabled(!workspace.isConnected)
                        Button("프로젝트 보관") {
                            guard let receipt = receipts[project.id] else { return }
                            Task { do { try await workspace.finishProject(project.id, snapshotID: receipt); receipts[project.id] = nil; notice = "프로젝트를 보관했습니다. 원문은 전체 기록에서 계속 찾을 수 있어요." } catch { notice = error.localizedDescription } }
                        }.disabled(receipts[project.id] == nil)
                    }
                    Divider()
                }
                ForEach(workspace.items("project").filter { $0.payload.text("phase") == "archived" }) { project in
                    HStack {
                        Image(systemName: "archivebox").foregroundStyle(.secondary)
                        Text(project.title).font(.callout)
                        Spacer()
                        Button("남겨둔 기록") { search = project.title; workspace.selectedProjectID = ""; workspace.selectedSubjectID = ""; tab = "records" }
                    }
                }
                Text("주제 없이도 기록과 프로젝트를 보관할 수 있습니다. 백업 첨부파일 합계는 32MB까지입니다.").font(.caption).foregroundStyle(.secondary)
            }.padding(32)
        }
    }
    private var contextEditor: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(contextKind == "subject" ? "주제 추가" : "프로젝트 추가").font(.title2)
            TextField("이름", text: $contextTitle)
            if contextKind == "project" {
                Picker("유형", selection: $contextProjectKind) {
                    Text("프로젝트").tag("project"); Text("시험 준비").tag("exam")
                }
                if contextProjectKind == "exam" { DatePicker("종료일", selection: $examDate, displayedComponents: .date) }
            }
            HStack {
                Button("취소") { contextSheet = false; contextTitle = "" }
                Button("만들기") { do {
                    var p: [String: WorkspaceValue] = ["title": .string(contextTitle), "phase": .string("active")]
                    if contextKind == "project" {
                        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "Asia/Seoul")
                        p["examDate"] = .string(contextProjectKind == "exam" ? f.string(from: examDate) : ""); p["kind"] = .string(contextProjectKind)
                    }
                    let e = try workspace.put(contextKind, p)
                    if contextKind == "subject" { subjectID = e.id } else { projectID = e.id }
                    contextTitle = ""; contextProjectKind = "project"; contextSheet = false; Task { await workspace.sync() }
                } catch { notice = error.localizedDescription } }.disabled(contextTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.textFieldStyle(.roundedBorder).padding(28).frame(width: 430)
    }
    private func load(_ e: WorkspaceEntity) {
        autosave?.cancel(); editingID = e.id; editingRevision = e.revision; workspace.selectedRecordID = e.id; title = e.title; text = e.payload.text("body")
        subjectID = e.payload.list("subjectIDs").first ?? ""; projectID = e.payload.list("projectIDs").first ?? ""
        try? workspace.observe("read", recordID: e.id)
    }
    private func newRecord() { autosave?.cancel(); editingID = nil; editingRevision = 0; workspace.selectedRecordID = nil; title = ""; text = ""; subjectID = workspace.selectedSubjectID; projectID = workspace.selectedProjectID }
    private func save() throws -> WorkspaceEntity? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !title.isEmpty else { return nil }
        let e = try workspace.saveRecord(id: editingID, title: title, body: text, subjectID: subjectID, projectID: projectID, expectedRevision: editingRevision); editingID = e.id; editingRevision = e.revision; return e
    }
    private func queueSave() { autosave?.cancel(); autosave = Task { try? await Task.sleep(for: .milliseconds(700)); guard !Task.isCancelled else { return }; do { _ = try save() } catch { notice = error.localizedDescription } } }
    private func commit() { do {
        if let e = try save(), text.range(of: #"(?:^|\n)\s*(?:\d+[.)]\s+)?\d{1,2}[./]\d{1,2}"#, options: .regularExpression) != nil { _ = try workspace.organize(e) }
        Task { await workspace.sync() }
    } catch { notice = error.localizedDescription } }
    private func organize() { do { if let e = try save() { notice = "\(try workspace.organize(e))개의 할 일로 정리했습니다."; Task { await workspace.sync() } } } catch { notice = error.localizedDescription } }
    private func resolve(_ id: String, keepCopy: Bool) { Task { do { try await workspace.resolveConflict(id, keepCopy: keepCopy); if let e = workspace.get(id) { load(e) } } catch { notice = error.localizedDescription } } }
    private func analyze(question: String = "") {
        guard !analyzing, question.count <= 2000 else { return }
        do {
            guard let source = try save() else { return }
            let owner = workspace.owner; analyzing = true
            Task {
                defer { analyzing = false }
                do {
                    await workspace.sync()
                    guard workspace.owner == owner, workspace.error == nil,
                          let synced = workspace.get(source.id), synced.pending != true, synced.remoteJSON == nil,
                          WorkspaceAnalysisSupport.contextMatches(synced.payload, source.payload) else {
                        throw DatabaseError.sqlite("원문 동기화와 다른 기기의 수정 내용을 먼저 확인해 주세요.")
                    }
                    let (value, _) = try await workspace.request("ai/analyze", body: .object([
                        "recordID": .string(source.id), "mode": .string(question.isEmpty ? "organize" : "question"),
                        "question": .string(question)]))
                    _ = try save()
                    _ = try workspace.saveAnalysis(source, result: value, expectedOwner: owner)
                    await workspace.sync()
                } catch { notice = error.localizedDescription }
            }
        } catch { notice = error.localizedDescription }
    }
    private func connectCalendar() { Task {
        await google.connect(includeCalendar: true)
        do { let credential = try google.calendarCredentials(); _ = try await workspace.request("calendar/connect", body: .object(credential.mapValues { .string($0) })); notice = "Google Calendar를 연결했습니다." } catch { notice = error.localizedDescription }
    } }
    private func exportBackup(_ project: WorkspaceEntity) {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "RAVIL-\(project.title)-backup.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { do { await workspace.sync(); try await workspace.exportBackup(projectID: project.id, to: url); notice = "백업 파일을 저장했습니다. 저장한 파일을 검사해 주세요." } catch { notice = error.localizedDescription } }
    }
    private func verifyBackup(_ project: WorkspaceEntity) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { do { receipts[project.id] = try await workspace.verifyBackup(projectID: project.id, at: url); notice = "백업의 기록과 첨부파일을 검사했습니다." } catch { notice = error.localizedDescription } }
    }
    private func attach() {
        do {
            guard let record = try save() else { notice = "먼저 기록을 적어 주세요."; return }
            let panel = NSOpenPanel(); panel.canChooseDirectories = false
            guard panel.runModal() == .OK, let url = panel.url else { return }
            Task { do { try await workspace.attachFile(url, recordID: record.id); notice = "파일을 연결했습니다." } catch { notice = error.localizedDescription } }
        } catch { notice = error.localizedDescription }
    }
}

private struct WorkspaceAccountSheet: View {
    @Bindable var workspace: PersonalWorkspace
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var name = ""
    @State private var create = false
    @State private var working = false
    @State private var error = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("계정 · 동기화").font(.title2.weight(.semibold))
            TextField("작업 공간 서버 주소", text: $workspace.baseURL).disabled(workspace.isConnected)
            if workspace.isConnected {
                Text(workspace.email); Text(workspace.status).foregroundStyle(.secondary)
                Button("백업 알림 받기") { Task { do { try await workspace.enableBackupNotifications() } catch { self.error = error.localizedDescription } } }
                if workspace.hasGuestRecords { Button("이 기기의 로그인 전 기록 연결") { Task { do { try await workspace.adoptGuest() } catch { self.error = error.localizedDescription } } } }
                Button("로그아웃") { Task { do { try await workspace.signOut() } catch { self.error = error.localizedDescription } } }
            } else {
                Toggle("새 계정 만들기", isOn: $create)
                if create { TextField("표시 이름", text: $name) }
                TextField("이메일", text: $email); SecureField("비밀번호 · 12자 이상", text: $password)
                Button(create ? "계정 만들기" : "로그인") { working = true; Task { do { try await workspace.signIn(email: email, password: password, name: create ? name : nil); password = "" } catch { self.error = error.localizedDescription }; working = false } }
                    .disabled(working || email.isEmpty || password.count < 12 || (create && name.isEmpty))
            }
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red) }
            Text("계정마다 기록을 구분합니다. 로그인 전 기록은 직접 연결할 수 있어요.").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("닫기") { dismiss() } }
        }.textFieldStyle(.roundedBorder).padding(28).frame(width: 470)
    }
}
