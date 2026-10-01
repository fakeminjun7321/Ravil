import SwiftUI

struct MaterialsView: View {
    @Bindable var model: AppModel

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $model.selectedMaterialID) {
                    ForEach(model.filteredMaterials) { material in
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: "doc.text")
                                .foregroundStyle(.secondary)
                                .frame(width: 18)
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(material.title)
                                    .font(.body.weight(.medium))
                                    .lineLimit(2)
                                HStack(spacing: 5) {
                                    Text([material.course.isEmpty ? "미분류" : material.course,
                                          material.documentKind].compactMap { $0 }.joined(separator: " · "))
                                        .lineLimit(1)
                                    if material.classificationNeedsReview {
                                        Image(systemName: "exclamationmark.circle")
                                            .help("분류 확인 필요")
                                            .accessibilityLabel("분류 확인 필요")
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 5)
                        .tag(material.id)
                    }
                }
                .listStyle(.inset)
                .overlay {
                    if model.filteredMaterials.isEmpty {
                        Text(model.selectedSubjectGroup.map { "\($0.title)에 자료가 없습니다" }
                             ?? "저장된 자료가 없습니다")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                if let group = model.selectedSubjectGroup {
                    Divider()
                    HStack {
                        Spacer()
                        Button("PDF 추가", systemImage: "plus") {
                            model.importPDFViaOpenPanel(courseID: nil, subjectName: group.title)
                        }
                        .fixedSize()
                    }
                    .controlSize(.small)
                    .padding(12)
                }
            }
            .frame(minWidth: 230, idealWidth: 285, maxWidth: 360)
            if let material = model.selectedMaterial,
               model.filteredMaterials.contains(where: { $0.id == material.id }) {
                MaterialDetailView(model: model, material: material)
                    .id(material.id)
                    .frame(minWidth: 380)
            } else if model.filteredMaterials.isEmpty, let group = model.selectedSubjectGroup {
                ContentUnavailableView("\(group.title)에 자료가 없습니다", systemImage: "folder")
                    .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("자료를 선택하세요", systemImage: "doc.text")
                    .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
