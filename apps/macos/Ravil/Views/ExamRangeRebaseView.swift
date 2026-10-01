import SwiftUI

struct ExamRangeRebaseView: View {
    let model: AppModel
    let scopeID: String
    let range: ExamMaterialRange
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var startPage: Int
    @State private var endPage: Int

    init(model: AppModel, scopeID: String, range: ExamMaterialRange, onSaved: @escaping () -> Void) {
        self.model = model
        self.scopeID = scopeID
        self.range = range
        self.onSaved = onSaved
        let pageCount = max(1, range.replacementPageCount ?? 1)
        let start = min(range.startPage, pageCount)
        _startPage = State(initialValue: start)
        _endPage = State(initialValue: max(start, min(range.endPage, pageCount)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("새 PDF 판본으로 범위 지정")
                .font(.title2.bold())
            Text(range.title)
                .font(.headline)
            Text("이전 \(range.startPage)~\(range.endPage)쪽을 자동으로 옮기지 않습니다. 새 PDF에서 쪽 위치를 확인한 뒤 저장해 주세요. 기존 퀴즈 카드는 기록으로 남지만 새 판본 퀴즈에는 나오지 않습니다.")
                .foregroundStyle(.secondary)
            if let path = range.replacementLocalPath {
                PDFMaterialPreview(url: URL(fileURLWithPath: path), initialPage: startPage)
                    .id(range.replacementMaterialID)
                    .frame(height: 310)
            }
            if let pageCount = range.replacementPageCount {
                Stepper("시작: \(startPage)쪽", value: $startPage, in: 1...max(1, endPage))
                Stepper("끝: \(endPage)쪽", value: $endPage,
                        in: startPage...max(startPage, pageCount))
                Text("새 판본 전체 \(pageCount)쪽")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("취소") { dismiss() }
                Button("범위 저장") {
                    guard let newID = range.replacementMaterialID else { return }
                    if model.rebaseExamScopeMaterial(scopeID: scopeID, oldMaterialID: range.materialID,
                                                      newMaterialID: newID, startPage: startPage,
                                                      endPage: endPage) {
                        onSaved()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(range.replacementMaterialID == nil)
            }
        }
        .padding(24)
        .frame(width: 580)
    }
}
