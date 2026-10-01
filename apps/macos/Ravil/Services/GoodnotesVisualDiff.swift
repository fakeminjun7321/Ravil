import AppKit
import CryptoKit
import Foundation
import PDFKit

struct GoodnotesVisualDiffResult: Sendable {
    let addedPages: [Int]
    let removedPages: [Int]
    let changedPages: [Int]
    let locationsCertain: Bool
}

enum GoodnotesVisualDiff {
    static func compare(previousPath: String, currentPath: String) throws -> GoodnotesVisualDiffResult {
        let old = try pageHashes(at: previousPath)
        let new = try pageHashes(at: currentPath)
        if old.count == new.count {
            let changed = new.indices.filter { new[$0] != old[$0] }.map { $0 + 1 }
            return GoodnotesVisualDiffResult(addedPages: [], removedPages: [],
                                             changedPages: changed, locationsCertain: true)
        }
        if old.count < new.count, Set(old).count == old.count,
           let added = unmatchedPages(subsequence: old, in: new) {
            return GoodnotesVisualDiffResult(addedPages: added, removedPages: [],
                                             changedPages: [], locationsCertain: true)
        }
        if new.count < old.count, Set(new).count == new.count,
           let removed = unmatchedPages(subsequence: new, in: old) {
            return GoodnotesVisualDiffResult(addedPages: [], removedPages: removed,
                                             changedPages: [], locationsCertain: true)
        }
        return GoodnotesVisualDiffResult(addedPages: [], removedPages: [],
                                         changedPages: [], locationsCertain: false)
    }

    private static func unmatchedPages(subsequence: [String], in full: [String]) -> [Int]? {
        var subIndex = 0
        var unmatched: [Int] = []
        for (index, hash) in full.enumerated() {
            if subIndex < subsequence.count && hash == subsequence[subIndex] {
                subIndex += 1
            } else {
                unmatched.append(index + 1)
            }
        }
        return subIndex == subsequence.count ? unmatched : nil
    }

    private static func pageHashes(at path: String) throws -> [String] {
        guard let document = PDFDocument(url: URL(fileURLWithPath: path)), document.pageCount > 0 else {
            throw DatabaseError.sqlite("비교할 PDF를 열 수 없습니다")
        }
        var hashes: [String] = []
        for index in 0..<document.pageCount {
            if Task<Never, Never>.isCancelled {
                throw CancellationError()
            }
            guard let page = document.page(at: index),
                  let data = page.thumbnail(of: NSSize(width: 300, height: 400), for: .mediaBox)
                    .tiffRepresentation else {
                throw DatabaseError.sqlite("PDF 페이지 그림을 비교할 수 없습니다")
            }
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            hashes.append(hash)
        }
        return hashes
    }
}
