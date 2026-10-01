import SwiftUI

struct GoodnotesClassificationEditor: View {
    let model: AppModel
    let material: MaterialItem
    @Environment(\.dismiss) private var dismiss
    @State private var subject: String
    @State private var documentKind: String
    @State private var teacherName: String

    private let subjects = ["켈큘", "천문", "미방", "일물", "현물", "국어", "영어", "물실", "프실"]

    init(model: AppModel, material: MaterialItem) {
        self.model = model
        self.material = material
        _subject = State(initialValue: GoodnotesClassifier.allowedSubjects.contains(material.course)
                         ? material.course : "")
        _documentKind = State(initialValue: material.documentKind == GoodnotesClassifier.unclassifiedKind
                              ? "" : (material.documentKind ?? ""))
        _teacherName = State(initialValue: material.teacherName ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("자료 분류 확인").font(.title2.bold())
            Text(material.title).font(.headline)
            Text("원본 Drive 파일과 보관된 PDF 판본은 바꾸지 않습니다. 여기서 확정한 분류는 이후 백업을 다시 가져와도 유지됩니다.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("과목", selection: $subject) {
                Text("과목 선택").tag("")
                ForEach(subjects, id: \.self) { Text($0).tag($0) }
            }
            TextField("자료 종류 (예: 학습지, 교재, 정리노트)", text: $documentKind)
                .textFieldStyle(.roundedBorder)
            TextField("교사 또는 작성자 (선택)", text: $teacherName)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("취소") { dismiss() }
                Button("분류 저장") {
                    if model.updateGoodnotesClassification(materialID: material.id,
                                                            subject: subject,
                                                            documentKind: documentKind,
                                                            teacherName: teacherName) {
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(subject.isEmpty || documentKind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 500)
    }
}
