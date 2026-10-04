import SwiftUI

struct PDFMaterialPreview: View {
    let url: URL
    let initialPage: Int
    let onPageChange: ((Int) -> Void)?
    @State private var pageIndex: Int
    @State private var pageCount = 0
    @State private var pageImage: CGImage?
    @State private var isRendering = true

    private struct Request: Hashable { let url: URL; let index: Int }

    init(url: URL, initialPage: Int = 1, onPageChange: ((Int) -> Void)? = nil) {
        self.onPageChange = onPageChange
        self.url = url
        self.initialPage = initialPage
        _pageIndex = State(initialValue: max(initialPage - 1, 0))
    }

    var body: some View {
        VStack(spacing: 10) {
            if pageCount > 0 {
                HStack(spacing: 12) {
                    Button("이전 페이지", systemImage: "chevron.left") { pageIndex = max(0, pageIndex - 1) }
                        .disabled(pageIndex == 0)
                    Text("\(pageIndex + 1) / \(pageCount)")
                        .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    Button("다음 페이지", systemImage: "chevron.right") { pageIndex = min(pageCount - 1, pageIndex + 1) }
                        .disabled(pageIndex >= pageCount - 1)
                    Spacer()
                }
            }
            if let pageImage {
                Image(pageImage, scale: 1, label: Text("PDF \(pageIndex + 1)쪽"))
                    .resizable().scaledToFit()
                    .frame(maxWidth: 820).frame(maxWidth: .infinity)
                    .padding(14)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            } else if isRendering {
                ProgressView("PDF 페이지를 불러오는 중")
                    .frame(maxWidth: .infinity, minHeight: 300)
            } else {
                ContentUnavailableView("PDF 페이지를 표시할 수 없습니다", systemImage: "doc.text.image")
                    .frame(maxWidth: .infinity, minHeight: 300)
            }
        }
        .task(id: Request(url: url, index: pageIndex)) {
            isRendering = true
            pageImage = nil
            do {
                let rendered = try await PDFPageRenderer.shared.render(url: url, page: pageIndex)
                guard !Task.isCancelled else { return }
                pageCount = rendered.pageCount
                pageIndex = rendered.pageIndex
                pageImage = rendered.image
                onPageChange?(rendered.pageIndex + 1)
                isRendering = false
            } catch {
                guard !Task.isCancelled else { return }
                pageImage = nil
                pageCount = 0
                isRendering = false
            }
        }
        .onChange(of: url) { _, _ in
            pageCount = 0
            pageIndex = max(initialPage - 1, 0)
        }
        .onChange(of: initialPage) { _, value in pageIndex = max(value - 1, 0) }
    }
}
