import SwiftUI

struct PreferencesView: View {
    @Bindable var model: AppModel
    @AppStorage("RavilDarkAppearance") private var darkAppearance = true

    var body: some View {
        Form {
            Section("화면") {
                Toggle("어두운 화면 사용", isOn: $darkAppearance)
                Text("끄면 macOS 화면 설정을 따릅니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("로컬 전사") {
                LabeledContent("Whisper 모델") {
                    TextField("모델 파일 경로", text: $model.modelPath)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Whisper 실행 파일") {
                    TextField("whisper-cli 경로", text: $model.executablePath)
                        .textFieldStyle(.roundedBorder)
                }
                Label(model.modelReady ? "모델 연결됨" : "경로를 확인해 주세요",
                      systemImage: model.modelReady ? "checkmark.circle.fill" : "exclamationmark.triangle")
                    .foregroundStyle(model.modelReady ? .green : .orange)
                if AppPaths.bundledModel != nil {
                    Text("앱에 포함된 모델로 기기에서 전사합니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("모델: OpenAI Whisper large-v3-turbo · 변환: whisper.cpp · MIT")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("출처, 파일 해시와 라이선스는 앱 번들의 Models/MODEL_CARD.md에 기록되어 있습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if AppPaths.bundledVADModel != nil {
                        Text("음성 구간 감지 모델: Silero VAD v6.2.0 · MIT")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("VAD 출처와 라이선스는 앱 번들의 Whisper/bin에 기록되어 있습니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Button("경로 저장") { model.saveModelPreferences() }
            }
            Section("내 데이터") {
                Text(model.databaseLocation)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            Section("Goodnotes 자동 갱신") {
                Text("선택한 Drive 폴더에서 새 PDF를 가져옵니다. 이전 판본은 보관됩니다.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("백업할 Drive 폴더 링크", text: $model.google.rootFolderID)
                    .textFieldStyle(.roundedBorder)
                Text("Drive 전체 읽기 권한이 필요하며, 실제 탐색은 선택한 폴더로 제한됩니다.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("설정 저장") { model.google.saveConfiguration() }
                    if model.google.isConnected {
                        if model.google.requiresReconnect {
                            Button("Google 계정 다시 연결") { Task { await model.google.connect() } }
                                .disabled(model.google.isConnecting || model.google.isSyncing)
                        }
                        Button("지금 변경 확인") { Task { await model.google.syncNow() } }
                            .disabled(model.google.isSyncing || model.google.isConnecting || model.google.requiresReconnect)
                        Button("연결 해제") { model.google.disconnect() }
                    } else {
                        Button("Google 계정 연결") { Task { await model.google.connect() } }
                            .disabled(!model.google.configurationReady || model.google.isConnecting)
                    }
                }
                Toggle("앱이 켜져 있는 동안 15분마다 확인", isOn: Binding(
                    get: { model.google.automaticEnabled },
                    set: { model.google.setAutomaticEnabled($0) }
                ))
                .disabled(!model.google.isConnected)
                if !model.google.configurationReady {
                    Text("이 빌드에는 Google 연결 설정이 아직 포함되지 않았습니다.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(model.google.status)
                        .font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup("개발자 설정") {
                    TextField("OAuth 클라이언트 ID", text: $model.google.clientID)
                        .textFieldStyle(.roundedBorder)
                        .disabled(model.google.isConnected)
                }
                if !model.google.lastSyncSummary.isEmpty {
                    Text(model.google.lastSyncSummary)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("저장 공간") {
                StorageUsageView()
            }
            Section("Codex") {
                TextField("Codex 실행 파일의 절대 경로", text: $model.codex.executablePath)
                    .textFieldStyle(.roundedBorder)
                Text("이 기기의 Codex 로그인 계정을 사용합니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(maxWidth: 900)
    }
}
