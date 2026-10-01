import AppKit
import Foundation
import PDFKit

enum MacPerformanceCheck {
    struct Input: Decodable { let database: String; let pdf: String }

    @MainActor static func run(inputURL: URL, outputURL: URL) async throws {
        let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: inputURL))
        let seed = URL(fileURLWithPath: input.database)
        let folder = outputURL.deletingLastPathComponent().appendingPathComponent("run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let copy = folder.appendingPathComponent("library.sqlite")
        try LibraryDatabase.backup(from: seed, to: copy)
        var measures: [String: Double] = [:]
        func timed<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
            let start = ProcessInfo.processInfo.systemUptime
            defer { measures[name] = (ProcessInfo.processInfo.systemUptime - start) * 1000 }
            return try body()
        }
        let database = try timed("openDatabaseMs") { try LibraryDatabase(location: copy, importLegacy: false) }
        let lectures = try timed("lecturesMs") { try database.lectures() }
        let materials = try timed("materialsMs") { try database.materials() }
        _ = try timed("coursesMs") { try database.courses() }
        _ = try timed("notesMs") { try database.notes() }
        _ = try timed("reclassifyMs") { try database.reclassifyGoodnotesMaterials() }
        let snapshot = try timed("altMetadataMs") { try AltFolderSnapshotReader.load() }
        if let snapshot {
            _ = try timed("altSyncMs") { try database.syncAlt(from: snapshot.sourceURL) }
        }
        for (index, query) in ["물리", "에너지", "the"].enumerated() {
            _ = try timed("search\(index)Ms") { try database.search(query) }
        }
        if let id = lectures.first?.id {
            _ = try timed("transcriptMs") { try database.transcript(for: id) }
            _ = try timed("intelligenceMs") { try database.intelligence(for: id) }
        }
        let pdfURL = URL(fileURLWithPath: input.pdf)
        guard let pdf = PDFDocument(url: pdfURL), pdf.pageCount > 0 else {
            throw DatabaseError.sqlite("성능 검사 PDF를 읽을 수 없습니다")
        }
        let indices = Array(Set([0, 1, 2, 10, 30, pdf.pageCount - 1].filter { $0 < pdf.pageCount })).sorted()
        var pageTimes: [Double] = []
        var optimizedTimes: [Double] = []
        var revisitTimes: [Double] = []
        let renderer = PDFPageRenderer()
        var encodedBytes = 0
        for index in indices {
            let start = ProcessInfo.processInfo.systemUptime
            let bytes: Int = try autoreleasepool {
                guard let document = PDFDocument(url: pdfURL), let page = document.page(at: index),
                      let tiff = page.thumbnail(of: NSSize(width: 1200, height: 1600), for: .mediaBox).tiffRepresentation,
                      let representation = NSBitmapImageRep(data: tiff),
                      let png = representation.representation(using: .png, properties: [:]) else {
                    throw DatabaseError.sqlite("PDF 렌더링 검사 실패")
                }
                return png.count
            }
            pageTimes.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            encodedBytes += bytes
            let renderStart = ProcessInfo.processInfo.systemUptime
            let page = try await renderer.render(url: pdfURL, page: index)
            guard page.pageIndex == index, page.pageCount == pdf.pageCount else {
                throw DatabaseError.sqlite("페이지 렌더링 결과가 요청과 다릅니다")
            }
            optimizedTimes.append((ProcessInfo.processInfo.systemUptime - renderStart) * 1000)
            let revisitStart = ProcessInfo.processInfo.systemUptime
            _ = try await renderer.render(url: pdfURL, page: index)
            revisitTimes.append((ProcessInfo.processInfo.systemUptime - revisitStart) * 1000)
        }
        let synchronous = try await responsiveness {
            _ = try database.importLocalPDF(from: pdfURL, courseID: nil)
        }
        let backgroundFolder = folder.appendingPathComponent("background")
        try FileManager.default.createDirectory(at: backgroundFolder, withIntermediateDirectories: true)
        let backgroundCopy = backgroundFolder.appendingPathComponent("library.sqlite")
        try LibraryDatabase.backup(from: seed, to: backgroundCopy)
        let observer = try LibraryDatabase(location: backgroundCopy, importLegacy: false)
        let asynchronous = try await responsiveness {
            _ = try await LocalPDFImporter.shared.importPDF(from: pdfURL, databaseURL: backgroundCopy,
                courseID: nil, lectureID: nil, subjectName: "현물")
        }
        guard try observer.materials().contains(where: { $0.course == "현물" && $0.pageCount == pdf.pageCount }) else {
            throw DatabaseError.sqlite("백그라운드 가져오기의 과목 또는 자료 저장 확인 실패")
        }
        let result: [String: Any] = ["measurements": measures,
            "lectureCount": lectures.count, "materialCount": materials.count, "pdfPageCount": pdf.pageCount,
            "legacyPDFRenderMs": pageTimes, "legacyEncodedBytes": encodedBytes,
            "optimizedPDFRenderMs": optimizedTimes, "cachedPDFRenderMs": revisitTimes,
            "documentLoads": await renderer.documentLoads, "rasterizations": await renderer.rasterizations,
            "cacheHits": await renderer.cacheHits,
            "synchronousImport": synchronous, "backgroundImport": asynchronous,
            "scope": "background/native component timing on a private DB copy; no GUI frame trace"]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: outputURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outputURL.path)
        print(String(data: data, encoding: .utf8)!)
    }

    @MainActor private static func responsiveness(_ action: () async throws -> Void) async throws -> [String: Double] {
        var maximumDelay = 0.0
        var ticks = 0
        var ready = false
        let heartbeat = Task { @MainActor in
            ready = true
            while !Task.isCancelled {
                let due = ProcessInfo.processInfo.systemUptime + 0.01
                do { try await Task.sleep(for: .milliseconds(10)) } catch { break }
                maximumDelay = max(maximumDelay, ProcessInfo.processInfo.systemUptime - due)
                ticks += 1
            }
        }
        while !ready { await Task.yield() }
        let start = ProcessInfo.processInfo.systemUptime
        do { try await action() }
        catch { heartbeat.cancel(); throw error }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        try await Task.sleep(for: .milliseconds(20))
        heartbeat.cancel()
        _ = await heartbeat.result
        return ["durationMs": elapsed * 1000, "maxMainActorTimerDelayMs": maximumDelay * 1000,
                "timerTicks": Double(ticks)]
    }
}
