import SwiftUI

struct RecordAnalysisView: View {
    let record: WorkspaceEntity
    let entities: [WorkspaceEntity]
    let busy: Bool
    let open: (String) -> Void
    let ask: (String) -> Void
    let addTask: (String, [String]) -> Void
    let applyTags: ([String]) -> Void
    @State private var question = ""
    @State private var selectedTags: Set<String> = []
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider()
            Text("기록에서 찾은 맥락").font(.headline)
            if let result = WorkspaceAnalysisSupport.current(record.payload) {
                if !result.text("summary").isEmpty {
                    Text("핵심 정리").font(.subheadline.weight(.semibold))
                    Text(result.text("summary")).textSelection(.enabled)
                }
                if result["insufficientEvidence"] == .bool(true) {
                    Text("답을 뒷받침할 기록이 충분하지 않아요.").font(.caption).foregroundStyle(.secondary)
                }
                if !result.text("answer").isEmpty {
                    Text(result.text("question").isEmpty ? "기록에 대한 답변" : result.text("question"))
                        .font(.subheadline.weight(.semibold))
                    Text(result.text("answer")).textSelection(.enabled)
                    evidence(result.list("answerEvidenceIDs"), sources: result["sources"]?.elements ?? [])
                }
                ForEach(Array((result["connections"]?.elements ?? []).enumerated()), id: \.offset) { _, connection in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(connection.object.text("reason")).font(.callout)
                        evidence([connection.object.text("recordID")], sources: result["sources"]?.elements ?? [])
                    }
                }
                if !result.list("tags").isEmpty {
                    HStack {
                        ForEach(result.list("tags"), id: \.self) { tag in
                            Toggle(tag, isOn: Binding(get: { selectedTags.contains(tag) }, set: { value in
                                if value { selectedTags.insert(tag) } else { selectedTags.remove(tag) }
                            })).toggleStyle(.button)
                        }
                        Button("태그 반영") { applyTags(Array(selectedTags)) }
                            .disabled(selectedTags.isEmpty || busy)
                    }.controlSize(.small)
                }
                ForEach(Array((result["suggestions"]?.elements ?? []).enumerated()), id: \.offset) { _, suggestion in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(suggestion.object.text("text"))
                            evidence(suggestion.object.list("evidenceIDs"), sources: result["sources"]?.elements ?? [])
                        }
                        Spacer()
                        Button("할 일로 추가") { addTask(suggestion.object.text("text"), suggestion.object.list("evidenceIDs")) }
                            .disabled(busy)
                    }
                }
            } else if let previous = record.payload["aiAnalysis"]?.object, !previous.isEmpty {
                Text("원문이나 연결이 바뀌어 이전 분석으로 보관했어요.").font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("이전 AI 결과") {
                    Text(previous.text("summary")).textSelection(.enabled)
                    if !previous.text("answer").isEmpty { Text(previous.text("answer")).textSelection(.enabled) }
                }
            } else if !record.payload.text("summary").isEmpty {
                DisclosureGroup("이전에 저장한 정리") { Text(record.payload.text("summary")).textSelection(.enabled) }
            }
            HStack {
                TextField("이 기록과 이전 생각에 대해 질문", text: $question)
                    .textFieldStyle(.roundedBorder).disabled(busy)
                Button("질문하기") { let value = question.trimmingCharacters(in: .whitespacesAndNewlines); if !value.isEmpty { ask(value) } }
                    .disabled(busy || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.font(.system(size: 13))
    }
    private func evidence(_ ids: [String], sources: [WorkspaceValue]) -> some View {
        HStack {
            ForEach(ids, id: \.self) { id in
                let source = sources.first { $0.object.text("id") == id }?.object
                let entity = entities.first { $0.id == id && !$0.deleted }
                let targetID = entity?.kind == "record" ? id : entity?.payload.text("recordID") ?? source?.text("recordID") ?? ""
                if let target = entities.first(where: { $0.id == targetID && !$0.deleted && $0.kind == "record" }) {
                    Button(target.title, systemImage: "doc.text") { open(target.id) }.buttonStyle(.link)
                }
            }
        }.font(.caption)
    }
}
