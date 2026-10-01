import SwiftUI

struct OCRReviewView: View {
    let model: AppModel
    let material: MaterialItem
    @Environment(\.dismiss) private var dismiss
    @State private var pages: [MaterialOCRPage] = []
    @State private var selectedPageID: String?
    @State private var draft = ""
    @State private var savedMessage = ""

    private var selectedPage: MaterialOCRPage? {
        pages.first { $0.id == selectedPageID }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("OCR 원문 대조").font(.title2.bold())
                    Text(material.title).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button("닫기") { dismiss() }
            }
            .padding(18)
            Divider()
            HStack(spacing: 0) {
                List(selection: $selectedPageID) {
                    ForEach(pages) { page in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(page.pageNumber)쪽")
                                Text(page.approvedAt == nil ? "검토 필요" : "검토 완료")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if page.meanConfidence < 0.6 {
                                Image(systemName: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                                    .accessibilityLabel("낮은 인식 신뢰도")
                            }
                        }
                        .tag(page.id)
                    }
                }
                .frame(width: 190)
                Divider()
                if let page = selectedPage,
                   let path = material.localPath {
                    PDFMaterialPreview(url: URL(fileURLWithPath: path),
                                       initialPage: page.pageNumber)
                        .id(page.id)
                        .frame(minWidth: 470)
                } else {
                    ContentUnavailableView("검토할 페이지가 없습니다", systemImage: "text.viewfinder")
                        .frame(minWidth: 470)
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    if let page = selectedPage {
                        Text("\(page.pageNumber)쪽 인식 결과")
                            .font(.headline)
                        Text("인식 신뢰도 평균 \(Int(page.meanConfidence * 100))% · 원본 PDF와 직접 대조해 주세요.")
                            .font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $draft)
                            .font(.body)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
                        HStack {
                            Button("자동 인식문으로 되돌리기") { draft = page.rawText }
                            Spacer()
                            Button("검토 완료로 저장") {
                                if model.approveGoodnotesOCR(pageID: page.id,
                                                             materialID: material.id,
                                                             correctedText: draft) {
                                    pages = model.goodnotesOCRPages(for: material.id)
                                    savedMessage = "\(page.pageNumber)쪽 검토를 저장했습니다."
                                }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        if !savedMessage.isEmpty {
                            Text(savedMessage).font(.caption).foregroundStyle(.green)
                        }
                        Text("원본 PDF와 자동 인식문은 수정되지 않습니다. 저장한 검토문만 별도로 검색에 사용합니다.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(18)
                .frame(width: 390)
            }
        }
        .frame(width: 1_180, height: 760)
        .task(id: material.id) {
            pages = model.goodnotesOCRPages(for: material.id)
            selectedPageID = pages.first?.id
            if let page = pages.first { draft = page.correctedText ?? page.rawText }
        }
        .onChange(of: selectedPageID) { _, id in
            savedMessage = ""
            if let page = pages.first(where: { $0.id == id }) {
                draft = page.correctedText ?? page.rawText
            }
        }
    }
}
