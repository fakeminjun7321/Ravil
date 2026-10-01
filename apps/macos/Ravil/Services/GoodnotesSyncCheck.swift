import AppKit
import Foundation

enum GoodnotesSyncCheck {
    static func run() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("RavilDriveSyncCheck-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let v1 = folder.appendingPathComponent("v1.pdf")
        let v2 = folder.appendingPathComponent("v2.pdf")
        try makePDF(at: v1, pages: 1)
        try makePDF(at: v2, pages: 2)
        let database = try LibraryDatabase(location: folder.appendingPathComponent("test.sqlite"), importLegacy: false)
        let source = FixtureSource(pdf: v1, revision: "r1", fileName: "배태윤T_학습지.pdf")
        let first = try await GoodnotesAutoSync(source: source, database: database,
                                               rootFolderID: "midterm-root").run()
        guard first.discoveredPDFs == 1, first.downloadedPDFs == 1,
              first.imported?.newVersions == 1,
              try database.materials().first?.course == "천문" else {
            throw DatabaseError.sqlite("Drive 자동 스캔/분류 검사가 실패했습니다")
        }
        // Simulate a document imported by an older classifier. The remote revision
        // stays unchanged, so only stored metadata should be refreshed.
        try database.execute("UPDATE goodnotes_documents SET subject = ?",
                             values: [GoodnotesClassifier.unclassifiedSubject])
        try database.execute("UPDATE goodnotes_classifications SET subject_source = 'review', needs_review = 1, confidence = 0")
        let unchanged = try await GoodnotesAutoSync(source: source, database: database,
                                                   rootFolderID: "midterm-root").run()
        guard unchanged.downloadedPDFs == 0, unchanged.imported == nil,
              unchanged.reclassifiedMaterials == 1, unchanged.libraryChanged,
              try database.materials().first?.course == "천문",
              try database.rows("SELECT COUNT(*) AS n FROM goodnotes_versions").first?["n"] == "1" else {
            throw DatabaseError.sqlite("변경 없는 PDF의 무다운로드 재분류 또는 판본 보존 검사가 실패했습니다")
        }
        let settled = try await GoodnotesAutoSync(source: source, database: database,
                                                  rootFolderID: "midterm-root").run()
        guard settled.reclassifiedMaterials == 0, !settled.libraryChanged else {
            throw DatabaseError.sqlite("변경 없는 재분류가 불필요한 화면 갱신을 요청했습니다")
        }
        let updated = FixtureSource(pdf: v2, revision: "r2", fileName: "배태윤T_학습지.pdf")
        let second = try await GoodnotesAutoSync(source: updated, database: database,
                                                rootFolderID: "midterm-root").run()
        guard second.imported?.newVersions == 1,
              try database.materials().first?.pageCount == 2,
              try database.rows("SELECT COUNT(*) AS n FROM goodnotes_versions").first?["n"] == "2" else {
            throw DatabaseError.sqlite("Drive 새 PDF 판본 보존 검사가 실패했습니다")
        }
        let renamed = FixtureSource(pdf: v2, revision: "r2", fileName: "새이름.pdf")
        let renameResult = try await GoodnotesAutoSync(source: renamed, database: database,
                                                      rootFolderID: "midterm-root").run()
        guard renameResult.downloadedPDFs == 1, renameResult.imported?.newVersions == 0,
              try database.materials().first?.title == "새이름.pdf" else {
            throw DatabaseError.sqlite("Drive 파일명 변경 검사가 실패했습니다")
        }
        let bad = FixtureSource(pdf: v2, revision: "r3", fileName: "../unsafe.pdf")
        do {
            _ = try await GoodnotesAutoSync(source: bad, database: database,
                                            rootFolderID: "midterm-root").run()
            throw DatabaseError.sqlite("안전하지 않은 Drive 이름이 수락되었습니다")
        } catch GoodnotesSyncError.unsafeName { }
        guard try database.rows("SELECT COUNT(*) AS n FROM goodnotes_versions").first?["n"] == "2" else {
            throw DatabaseError.sqlite("실패한 Drive 스캔이 기존 판본을 변경했습니다")
        }
        do {
            _ = try await GoodnotesAutoSync(source: DuplicateFolderSource(), database: database,
                                            rootFolderID: "midterm-root").run()
            throw DatabaseError.sqlite("동명 Drive 폴더의 PDF 경로 충돌을 놓쳤습니다")
        } catch GoodnotesSyncError.duplicatePath { }
        guard try database.rows("SELECT COUNT(*) AS n FROM goodnotes_versions").first?["n"] == "2" else {
            throw DatabaseError.sqlite("동명 폴더 경로 충돌 후 DB 판본이 변경됐습니다")
        }
        print("Ravil Drive sync check: nested scan, classification, unchanged reclassification, new version, rename, unsafe-path and duplicate-folder guards passed")
    }

    private struct FixtureSource: GoodnotesDriveSource {
        let pdf: URL
        let revision: String
        let fileName: String

        func children(of folderID: String) async throws -> [DrivePDF] {
            if folderID == "midterm-root" {
                return [DrivePDF(id: "semester-folder", name: "2026년 2학기",
                                 mimeType: "application/vnd.google-apps.folder",
                                 revision: nil, modifiedAt: nil, size: nil)]
            }
            if folderID == "semester-folder" {
                return [DrivePDF(id: "astronomy-folder", name: "Astronomy",
                                 mimeType: "application/vnd.google-apps.folder",
                                 revision: nil, modifiedAt: nil, size: nil)]
            }
            if folderID == "astronomy-folder" {
                return [DrivePDF(id: "goodnotes-file", name: fileName,
                                 mimeType: "application/pdf", revision: revision,
                                 modifiedAt: "2026-09-25T00:00:00Z", size: 2048)]
            }
            throw GoodnotesSyncError.invalidFolder
        }

        func downloadPDF(id: String, to destination: URL) async throws {
            guard id == "goodnotes-file" else { throw GoodnotesSyncError.invalidResponse }
            try FileManager.default.copyItem(at: pdf, to: destination)
        }
    }

    private struct DuplicateFolderSource: GoodnotesDriveSource {
        func children(of folderID: String) async throws -> [DrivePDF] {
            if folderID == "midterm-root" {
                return ["first", "second"].map {
                    DrivePDF(id: $0, name: "Astronomy", mimeType: "application/vnd.google-apps.folder",
                             revision: nil, modifiedAt: nil, size: nil)
                }
            }
            if folderID == "first" || folderID == "second" {
                return [DrivePDF(id: folderID + "-pdf", name: "same.pdf",
                                 mimeType: "application/pdf", revision: "r1",
                                 modifiedAt: nil, size: 1_024)]
            }
            throw GoodnotesSyncError.invalidFolder
        }

        func downloadPDF(id: String, to destination: URL) async throws {
            throw GoodnotesSyncError.invalidResponse
        }
    }

    private static func makePDF(at url: URL, pages: Int) throws {
        var box = CGRect(x: 0, y: 0, width: 150, height: 180)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw DatabaseError.sqlite("테스트 PDF를 만들 수 없습니다")
        }
        for _ in 0..<pages {
            context.beginPDFPage(nil)
            context.setFillColor(NSColor.white.cgColor)
            context.fill(box)
            context.endPDFPage()
        }
        context.closePDF()
    }
}
