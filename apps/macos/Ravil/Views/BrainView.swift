import SwiftUI

struct BrainView: View {
    @Bindable var model: AppModel
    @Bindable var brain: BrainStore
    init(model: AppModel) { self.model = model; self.brain = model.brain }
    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 12) {
                Text("근거 자료").font(.title2)
                Picker("범위", selection: $model.brainLectureID) {
                    Text("모든 강의·PDF·노트").tag(String?.none)
                    ForEach(model.lectures) { lecture in Text(lecture.title).tag(Optional(lecture.id)) }
                }
                HStack {
                    TextField("찾을 개념·키워드", text: $brain.query).textFieldStyle(.roundedBorder).onSubmit(search)
                    Button("찾기", action: search).disabled(brain.searching || brain.client.sending)
                }
                Text("함께 살펴볼 근거를 최대 6개 선택하세요. OCR과 전사는 오류가 있을 수 있습니다.")
                    .font(.caption).foregroundStyle(.secondary)
                if brain.searching { ProgressView() }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(brain.sources) { source in
                            VStack(alignment: .leading, spacing: 6) {
                                Toggle(isOn: Binding(get: { brain.selected.contains(source.id) }, set: { value in
                                    if value { if brain.selected.count < 6 { brain.selected.insert(source.id) } }
                                    else { brain.selected.remove(source.id) }
                                })) { Text(source.title + " · " + source.location).font(.subheadline.weight(.medium)) }
                                .disabled(brain.client.sending || (!brain.selected.contains(source.id) && brain.selected.count >= 6))
                                Text(String(source.text.prefix(1600))).font(.caption).textSelection(.enabled)
                                Button("원문 열기") { model.openBrainSource(source) }.buttonStyle(.link)
                            }
                            Divider()
                        }
                    }
                }
            }.padding(18).frame(minWidth: 300, idealWidth: 400, maxWidth: 500)
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("세컨드 브레인").font(.title2)
                    Spacer()
                    if brain.client.connected {
                        Text(brain.client.status).font(.caption).foregroundStyle(.secondary)
                    } else { Button("Codex 연결") { brain.client.connect() } }
                }
                if !brain.client.availableModels.isEmpty {
                    Picker("답변 모델", selection: $brain.client.selectedModel) {
                        ForEach(brain.client.availableModels, id: \.self) { Text($0).tag(Optional($0)) }
                    }.disabled(brain.client.sending)
                }
                TextField("선택한 자료를 종합해서 물어보기", text: $brain.question, axis: .vertical)
                    .lineLimit(2...5).textFieldStyle(.roundedBorder)
                HStack {
                    Text("선택한 \(brain.selected.count)개 발췌와 질문이 Codex로 전송됩니다.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("선택 자료로 질문") { brain.ask() }
                        .disabled(brain.selected.isEmpty || brain.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || brain.client.sending || !brain.client.accountConnected)
                        .buttonStyle(.borderedProminent)
                }
                if let error = brain.error ?? brain.client.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        if brain.client.sending {
                            ProgressView("자료를 종합하는 중")
                            if let message = brain.client.messages.last { Text(message.text).textSelection(.enabled) }
                        }
                        ForEach(brain.answers) { answer in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(answer.question).font(.headline)
                                Text(answer.answer).textSelection(.enabled)
                                if let warning = BrainGrounding.warning(answer: answer.answer, sourceCount: answer.sources.count) {
                                    Text(warning).font(.caption).foregroundStyle(.orange)
                                }
                                Text("답변 당시의 근거").font(.caption.weight(.semibold))
                                ForEach(Array(answer.sources.enumerated()), id: \.element.id) { index, source in
                                    DisclosureGroup {
                                        Text(String(source.text.prefix(1600))).font(.caption).textSelection(.enabled)
                                        Button("원문 열기") { model.openBrainSource(source) }.buttonStyle(.link)
                                    } label: {
                                        Text("[\(index+1)] \(source.title) · \(source.location)")
                                    }
                                }
                                Text(answer.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                            }
                            Divider()
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(20).frame(minWidth: 380, maxWidth: .infinity)
        }
        .onAppear { brain.loadHistory(database: model.database); if model.brainLectureID != nil { search() } }
        .onChange(of: model.brainLectureID) { _, _ in search() }
        .onChange(of: brain.client.sending) { _, sending in if !sending { brain.complete(database: model.database) } }
    }
    private func search() {
        guard !brain.client.sending else { return }
        brain.search(databaseURL: URL(fileURLWithPath: model.databaseLocation), lectureID: model.brainLectureID)
    }
}
