import SwiftUI

struct TranscriptionOptionsSheet: View {
    let model: AppModel
    let lecture: LectureItem
    @Environment(\.dismiss) private var dismiss
    @State private var language: String

    init(model: AppModel, lecture: LectureItem) {
        self.model = model
        self.lecture = lecture
        _language = State(initialValue: model.transcriptionLanguage)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(lecture.status == "recorded" ? "강의 전사" : "강의 다시 전사")
                .font(.title2.bold())
            Text(lecture.title).font(.headline)
            Picker("음성 언어", selection: $language) {
                Text("자동 감지").tag("auto")
                Text("한국어").tag("ko")
                Text("English").tag("en")
                Text("日本語").tag("ja")
                Text("中文").tag("zh")
            }
            Text("짧은 녹음에서는 자동 언어 판별이 틀릴 수 있습니다. 언어를 알고 있다면 직접 선택해 주세요.")
                .font(.caption).foregroundStyle(.secondary)
            if lecture.status != "recorded" {
                Text("기존 전사 구간과 근거 기록은 보존합니다. 새 결과가 강의와 검색에 표시됩니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("취소") { dismiss() }
                Button("전사 시작") {
                    model.transcribeLecture(lecture.id, language: language)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isTranscribing || !model.modelReady)
            }
        }
        .padding(24)
        .frame(width: 470)
    }
}
