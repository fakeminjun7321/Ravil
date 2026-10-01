import AppKit
import PDFKit
import SwiftUI

struct PDFMaterialPreview: View {
    let url: URL
    let initialPage: Int

    @State private var document: PDFDocument?
    @State private var pageIndex = 0
    @State private var pageImage: NSImage?
    @State private var isRendering = false
    @State private var renderTask: Task<Void, Never>?

    init(url: URL, initialPage: Int = 1) {
        self.url = url
        self.initialPage = initialPage
    }

    var body: some View {
        VStack(spacing: 10) {
            if let document, document.pageCount > 0 {
                HStack(spacing: 12) {
                    Button("이전 페이지", systemImage: "chevron.left") {
                        pageIndex = max(0, pageIndex - 1)
                    }
                    .disabled(pageIndex == 0)
                    Text("\(pageIndex + 1) / \(document.pageCount)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Button("다음 페이지", systemImage: "chevron.right") {
                        pageIndex = min(document.pageCount - 1, pageIndex + 1)
                    }
                    .disabled(pageIndex >= document.pageCount - 1)
                    Spacer()
                }
                if let pageImage {
                    Image(nsImage: pageImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 820)
                        .frame(maxWidth: .infinity)
                        .padding(14)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                } else if isRendering {
                    ProgressView("PDF 페이지를 불러오는 중")
                        .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    ContentUnavailableView("PDF 페이지를 표시할 수 없습니다", systemImage: "doc.text.image")
                        .frame(maxWidth: .infinity, minHeight: 300)
                }
            } else {
                ContentUnavailableView("PDF를 열 수 없습니다", systemImage: "doc.text.image")
                    .frame(maxWidth: .infinity, minHeight: 300)
            }
        }
        .task(id: url) {
            renderTask?.cancel()
            document = PDFDocument(url: url)
            pageIndex = min(max(initialPage - 1, 0), max((document?.pageCount ?? 1) - 1, 0))
            renderPage()
        }
        .onChange(of: pageIndex) { _, _ in renderPage() }
        .onDisappear { renderTask?.cancel() }
    }

    private func renderPage() {
        renderTask?.cancel()
        guard let document, document.page(at: pageIndex) != nil else {
            pageImage = nil
            isRendering = false
            return
        }
        let currentURL = url
        let currentPage = pageIndex
        let modified = (try? currentURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?
            .timeIntervalSince1970 ?? 0
        let cacheKey = "\(currentURL.path)#\(modified)#\(currentPage)" as NSString
        if let data = PDFPageImageCache.shared.object(forKey: cacheKey) {
            pageImage = NSImage(data: data as Data)
            isRendering = false
            return
        }
        pageImage = nil
        isRendering = true
        renderTask = Task { @MainActor in
            let worker = Task.detached(priority: .userInitiated) { () -> Data? in
                guard !Task.isCancelled,
                      let pdf = PDFDocument(url: currentURL),
                      let page = pdf.page(at: currentPage) else { return nil }
                let image = page.thumbnail(of: NSSize(width: 1200, height: 1600), for: .mediaBox)
                guard !Task.isCancelled,
                      let tiff = image.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
                return bitmap.representation(using: .png, properties: [:])
            }
            let data = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, currentURL == url, currentPage == pageIndex else { return }
            if let data {
                PDFPageImageCache.shared.setObject(data as NSData, forKey: cacheKey, cost: data.count)
                pageImage = NSImage(data: data)
            } else {
                pageImage = nil
            }
            isRendering = false
        }
    }
}

private enum PDFPageImageCache {
    static let shared: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.totalCostLimit = 32 * 1_048_576
        return cache
    }()
}
