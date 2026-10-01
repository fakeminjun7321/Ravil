import SwiftUI

struct CodexView: View {
    @Bindable var client: CodexAppServerClient
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Codex")
                        .font(.headline)
                    Text(client.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !client.availableModels.isEmpty {
                    Picker("모델", selection: $client.selectedModel) {
                        ForEach(client.availableModels, id: \.self) { model in
                            Text(model).tag(Optional(model))
                        }
                    }
                    .frame(maxWidth: 200)
                    .disabled(client.sending)
                }
                if client.connected {
                    Button("연결 끊기") { client.disconnect() }
                } else {
                    Button("연결") { client.connect() }
                }
            }
            .padding(18)

            Divider()

            if client.messages.isEmpty {
                ContentUnavailableView {
                    Label("Codex", systemImage: "bubble.left.and.text.bubble.right")
                } description: {
                    Text("질문은 Codex로 전송됩니다. 보관함 자료는 자동 첨부되지 않습니다.")
                        .frame(maxWidth: 480)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(client.messages) { message in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(message.role == "user" ? "나" : "Codex")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Text(message.text.isEmpty ? "응답 중…" : message.text)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(.vertical, 10)
                                .id(message.id)
                            }
                        }
                        .padding(20)
                    }
                    .onChange(of: client.messages.count) { _, _ in
                        if let id = client.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
            }

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if let error = client.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                HStack(alignment: .bottom, spacing: 10) {
                    TextField("Codex에게 질문", text: $draft, axis: .vertical)
                        .lineLimit(2...6)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!client.accountConnected || client.selectedModel == nil || client.sending)
                        .onSubmit(send)
                    Button("보내기", action: send)
                        .buttonStyle(.borderedProminent)
                        .disabled(!client.accountConnected || client.selectedModel == nil || client.sending ||
                                  draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text("읽기 전용 · 종료하면 대화가 패널에서 사라집니다")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(16)
        }
    }

    private func send() {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        client.send(value)
        draft = ""
    }
}
