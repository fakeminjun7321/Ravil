import AppKit
import Foundation
import ImageIO
import PDFKit

enum PDFPerformanceRegressionCheck {
    @MainActor static func run(folder: URL) async throws {
        guard !FileManager.default.fileExists(atPath: folder.path) else {
            throw DatabaseError.sqlite("검사 출력 폴더는 새 경로여야 합니다")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        let source = folder.appendingPathComponent("fixture.pdf")
        try makePDF(at: source, color: .systemBlue)
        let renderer = PDFPageRenderer()
        let first = try await renderer.render(url: source, page: 0)
        let cached = try await renderer.render(url: source, page: 0)
        let clamped = try await renderer.render(url: source, page: 99)
        guard first.pageIndex == 0, clamped.pageIndex == 2,
              await renderer.documentLoads == 1, await renderer.cacheHits >= 1,
              pixels(first.image) == pixels(cached.image) else {
            throw DatabaseError.sqlite("문서 재사용·캐시·페이지 범위 검사 실패")
        }

        guard let document = PDFDocument(url: source), let page = document.page(at: 0),
              let tiff = page.thumbnail(of: NSSize(width: 1200, height: 1600), for: .mediaBox).tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]),
              let legacy = NSBitmapImageRep(data: png)?.cgImage else {
            throw DatabaseError.sqlite("이전 렌더 경로의 비교 이미지를 만들 수 없습니다")
        }
        let before = pixels(legacy), after = pixels(first.image)
        guard legacy.width == first.image.width, legacy.height == first.image.height,
              before.count == after.count else { throw DatabaseError.sqlite("PDF 해상도가 달라졌습니다") }
        let meanPixelDifference = zip(before, after).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(before.count)
        guard meanPixelDifference < 1 else { throw DatabaseError.sqlite("PDF 렌더 결과가 기준과 달라졌습니다") }
        try png.write(to: folder.appendingPathComponent("before.png"))
        try savePNG(first.image, to: folder.appendingPathComponent("after.png"))

        let databaseURL = folder.appendingPathComponent("library.sqlite")
        let database = try LibraryDatabase(location: databaseURL, importLegacy: false)
        let importer = LocalPDFImporter()
        let original = try await importer.importPDF(from: source, databaseURL: databaseURL,
            courseID: nil, lectureID: nil, subjectName: "현물")
        let repeated = try await importer.importPDF(from: source, databaseURL: databaseURL,
            courseID: nil, lectureID: nil, subjectName: "현물")
        guard original.id == repeated.id, original.course == "현물" else {
            throw DatabaseError.sqlite("백그라운드 가져오기가 과목 또는 중복 자료를 잘못 처리했습니다")
        }
        let oldDate = try FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate]
        let replacement = folder.appendingPathComponent("replacement.pdf")
        try makePDF(at: replacement, color: .systemOrange)
        try Data(contentsOf: replacement).write(to: source, options: .atomic)
        if let oldDate { try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: source.path) }
        let changed = try await renderer.render(url: source, page: 0)
        guard pixels(first.image) != pixels(changed.image), await renderer.documentLoads == 2 else {
            throw DatabaseError.sqlite("같은 경로의 PDF 변경이 캐시에 반영되지 않았습니다")
        }
        let version = try await importer.importPDF(from: source, databaseURL: databaseURL,
            courseID: nil, lectureID: nil, subjectName: "현물")
        let reopened = try LibraryDatabase(location: databaseURL, importLegacy: false)
        guard version.id != original.id,
              try reopened.rows("SELECT COUNT(*) AS n FROM course_materials").first?["n"] == "2",
              let oldPath = original.localPath, FileManager.default.fileExists(atPath: oldPath),
              try reopened.rows("SELECT COUNT(*) AS n FROM courses WHERE name = '현물'").first?["n"] == "1" else {
            throw DatabaseError.sqlite("PDF 판본 이력 또는 재열기 검사가 실패했습니다")
        }
        let invalid = folder.appendingPathComponent("invalid.pdf")
        try Data("not a PDF".utf8).write(to: invalid)
        var rejected = false
        do { _ = try await importer.importPDF(from: invalid, databaseURL: databaseURL, courseID: nil, lectureID: nil, subjectName: nil) }
        catch { rejected = true }
        guard rejected, try database.rows("SELECT COUNT(*) AS n FROM course_materials").first?["n"] == "2" else {
            throw DatabaseError.sqlite("손상된 PDF가 저장됐습니다")
        }
        let cancelled = Task { () throws -> RenderedPDFPage in
            try Task.checkCancellation()
            return try await renderer.render(url: source, page: 1)
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; throw DatabaseError.sqlite("취소된 페이지 요청이 수락됐습니다") }
        catch is CancellationError {}
        let report: [String: Any] = ["meanPixelDifference": meanPixelDifference,
            "width": first.image.width, "height": first.image.height,
            "cacheAndInvalidation": true, "subjectAndDeduplication": true,
            "versionHistoryAndReopen": true, "invalidPDFRejected": true, "cancellation": true,
            "fixture": "generated test material, not a user's document"]
        let output = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try output.write(to: folder.appendingPathComponent("report.json"))
        print(String(data: output, encoding: .utf8)!)
    }

    @MainActor private static func makePDF(at url: URL, color: NSColor) throws {
        var box = CGRect(x: 0, y: 0, width: 420, height: 560)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw DatabaseError.sqlite("검사용 PDF 생성 실패")
        }
        for index in 1...3 {
            context.beginPDFPage(nil)
            context.setFillColor(NSColor.white.cgColor); context.fill(box)
            context.setFillColor(color.cgColor); context.fill(CGRect(x: 30, y: 395, width: 360, height: 110))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            NSAttributedString(string: "Ravil PDF 검사 · \(index)\n한글·숫자·색상 표시\n0123456789 / E = mc²",
                attributes: [.font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor.black])
                .draw(in: CGRect(x: 35, y: 180, width: 350, height: 150))
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
    }

    private static func pixels(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    private static func savePNG(_ image: CGImage, to url: URL) throws {
        guard let target = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw DatabaseError.sqlite("PNG 검사 파일 생성 실패")
        }
        CGImageDestinationAddImage(target, image, nil)
        guard CGImageDestinationFinalize(target) else { throw DatabaseError.sqlite("PNG 저장 실패") }
    }
}
