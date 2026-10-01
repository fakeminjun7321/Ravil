import AppKit
import Foundation
import PDFKit

struct RenderedPDFPage: Sendable {
    let image: CGImage
    let pageIndex: Int
    let pageCount: Int
}

/// Serial PDFKit access and a decoded-pixel budget. Cancelled queued requests
/// are discarded before rendering; pages never round-trip through TIFF/PNG.
actor PDFPageRenderer {
    static let shared = PDFPageRenderer()
    private var document: PDFDocument?
    private var documentIdentity: String?
    private let cache = NSCache<NSString, Entry>()
    private(set) var documentLoads = 0
    private(set) var rasterizations = 0
    private(set) var cacheHits = 0

    private final class Entry: NSObject {
        let page: RenderedPDFPage
        init(_ page: RenderedPDFPage) { self.page = page }
    }

    init() {
        cache.totalCostLimit = 32 * 1_048_576
        cache.countLimit = 4
    }

    func render(url: URL, page requestedPage: Int) throws -> RenderedPDFPage {
        try Task.checkCancellation()
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let stamp = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let identity = "\(url.standardizedFileURL.path)#\(stamp)#\(size)#\(inode)"
        if documentIdentity != identity {
            guard let next = PDFDocument(url: url), next.pageCount > 0, !next.isLocked else {
                throw DatabaseError.sqlite("PDF를 열 수 없습니다")
            }
            document = next
            documentIdentity = identity
            documentLoads += 1
        }
        guard let document else { throw DatabaseError.sqlite("PDF를 열 수 없습니다") }
        let index = min(max(requestedPage, 0), document.pageCount - 1)
        let key = "\(identity)#\(index)" as NSString
        if let hit = cache.object(forKey: key) {
            cacheHits += 1
            return hit.page
        }
        let rendered: RenderedPDFPage = try autoreleasepool {
            guard let page = document.page(at: index) else {
                throw DatabaseError.sqlite("PDF 페이지를 찾을 수 없습니다")
            }
            let thumbnail = page.thumbnail(of: NSSize(width: 1200, height: 1600), for: .mediaBox)
            guard let image = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw DatabaseError.sqlite("PDF 페이지를 표시할 수 없습니다")
            }
            return RenderedPDFPage(image: image, pageIndex: index, pageCount: document.pageCount)
        }
        try Task.checkCancellation()
        rasterizations += 1
        cache.setObject(Entry(rendered), forKey: key, cost: rendered.image.bytesPerRow * rendered.image.height)
        return rendered
    }
}
