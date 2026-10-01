import SwiftUI
import PDFKit

@main
enum RavilLauncher {
    static func main() {
        if let flag = CommandLine.arguments.firstIndex(of: "--pdf-performance-regression-check") {
            guard CommandLine.arguments.indices.contains(flag + 1) else { exit(2) }
            Task { @MainActor in
                do {
                    try await PDFPerformanceRegressionCheck.run(folder: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
                    exit(0)
                } catch { fputs("PDF regression check failed: \(error.localizedDescription)\n", stderr); exit(1) }
            }
            dispatchMain()
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--mac-performance-check") {
            guard CommandLine.arguments.indices.contains(flag + 2) else {
                fputs("usage: Ravil --mac-performance-check <private-input.json> <report.json>\n", stderr)
                exit(2)
            }
            Task { @MainActor in
                do {
                    try await MacPerformanceCheck.run(inputURL: URL(fileURLWithPath: CommandLine.arguments[flag + 1]),
                        outputURL: URL(fileURLWithPath: CommandLine.arguments[flag + 2]))
                    exit(0)
                } catch { fputs("Performance check failed: \(error.localizedDescription)\n", stderr); exit(1) }
            }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--goodnotes-classification-check") {
            do {
                try GoodnotesClassificationCheck.run()
                try GoodnotesReclassificationCheck.run()
                try SubjectFolderCheck.run()
            } catch {
                fputs("Ravil classification check failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
            return
        }
        if CommandLine.arguments.contains("--google-drive-http-check") {
            Task {
                do { try await GoogleDriveSourceCheck.run(); exit(0) }
                catch {
                    fputs("Ravil Drive HTTP check failed: \(error.localizedDescription)\n", stderr)
                    exit(1)
                }
            }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--google-oauth-loopback-check") {
            Task { @MainActor in
                do { try await GoogleAccountCheck.run(); exit(0) }
                catch {
                    fputs("Ravil Google OAuth loopback check failed: \(error.localizedDescription)\n", stderr)
                    exit(1)
                }
            }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--codex-models-check") {
            Task { @MainActor in
                let client = CodexAppServerClient()
                client.connect()
                for _ in 0..<100 {
                    if !client.availableModels.isEmpty || client.errorMessage != nil { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                print("Ravil Codex models: \(client.availableModels.joined(separator: ", "))")
                if let error = client.errorMessage { fputs("\(error)\n", stderr) }
                let passed = client.selectedModel != nil
                client.disconnect()
                exit(passed ? 0 : 1)
            }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--codex-turn-check") {
            Task { @MainActor in
                let client = CodexAppServerClient()
                client.connect()
                for _ in 0..<100 {
                    if client.selectedModel != nil || client.errorMessage != nil { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                if client.accountConnected {
                    client.send("Reply with exactly RAVIL_OK. Do not use tools.")
                    for _ in 0..<300 {
                        if !client.sending || client.errorMessage != nil { break }
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                }
                let answer = client.messages.last?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let passed = answer.contains("RAVIL_OK") && !client.sending
                print("Ravil Codex turn: \(passed ? "response received" : "not verified")")
                if !passed { fputs("\(client.errorMessage ?? client.status)\n", stderr) }
                client.disconnect()
                exit(passed ? 0 : 1)
            }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--codex-connection-check") {
            Task { @MainActor in
                let client = CodexAppServerClient()
                client.connect()
                for _ in 0..<50 {
                    if client.accountConnected || client.errorMessage != nil ||
                       client.status == "Codex 계정 로그인이 필요합니다" { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                let passed = client.connected && client.accountConnected
                print("Ravil Codex App Server: \(passed ? "handshake and account verified" : "not connected")")
                if !passed { fputs("\(client.errorMessage ?? client.status)\n", stderr) }
                client.disconnect()
                exit(passed ? 0 : 1)
            }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--goodnotes-sync-check") {
            Task {
                do { try await GoodnotesSyncCheck.run(); exit(0) }
                catch {
                    fputs("Ravil Drive sync check failed: \(error.localizedDescription)\n", stderr)
                    exit(1)
                }
            }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--study-check") {
            do { try StudyCheck.run() }
            catch {
                fputs("Ravil study check failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
            return
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--search-benchmark") {
            guard CommandLine.arguments.indices.contains(flag + 1) else {
                fputs("usage: Ravil --search-benchmark <query>\n", stderr)
                exit(2)
            }
            do {
                let database = try LibraryDatabase()
                var times: [Double] = []
                var hitCount = 0
                for _ in 0..<5 {
                    let started = ProcessInfo.processInfo.systemUptime
                    hitCount = try database.search(CommandLine.arguments[flag + 1]).count
                    times.append((ProcessInfo.processInfo.systemUptime - started) * 1_000)
                }
                let sorted = times.sorted()
                let result: [String: Any] = ["runs": 5, "hits": hitCount,
                                             "minMs": sorted[0], "medianMs": sorted[2],
                                             "maxMs": sorted[4]]
                let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
                print(String(decoding: data, as: UTF8.self))
            } catch {
                fputs("Ravil search benchmark failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
            return
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--goodnotes-compare") {
            guard CommandLine.arguments.indices.contains(flag + 1) else {
                fputs("usage: Ravil --goodnotes-compare <material-id>\n", stderr)
                exit(2)
            }
            do {
                let versions = try LibraryDatabase().goodnotesVersions(for: CommandLine.arguments[flag + 1])
                guard versions.count >= 2 else { throw DatabaseError.sqlite("이전 판본이 없습니다") }
                let diff = try GoodnotesVisualDiff.compare(previousPath: versions[1].localPath,
                                                           currentPath: versions[0].localPath)
                let result: [String: Any] = ["currentVersion": versions[0].version,
                                             "previousVersion": versions[1].version,
                                             "previousPages": versions[1].pageCount,
                                             "currentPages": versions[0].pageCount,
                                             "addedPages": diff.addedPages,
                                             "removedPages": diff.removedPages,
                                             "changedPages": diff.changedPages,
                                             "locationsCertain": diff.locationsCertain]
                let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
                print(String(decoding: data, as: UTF8.self))
            } catch {
                fputs("Ravil Goodnotes comparison failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
            return
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--goodnotes-import-preview") {
            guard CommandLine.arguments.indices.contains(flag + 1) else {
                fputs("usage: Ravil --goodnotes-import-preview <manifest.json>\n", stderr)
                exit(2)
            }
            do {
                let folder = FileManager.default.temporaryDirectory
                    .appendingPathComponent("RavilGoodnotesPreview-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: folder) }
                let copy = folder.appendingPathComponent("library.sqlite")
                try LibraryDatabase.backup(from: AppPaths.database, to: copy)
                let database = try LibraryDatabase(location: copy, importLegacy: false)
                let report = try database.importGoodnotesMidterm(
                    manifestURL: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
                let result: [String: Any] = ["imported": report.imported,
                                             "newVersions": report.newVersions,
                                             "unchanged": report.unchanged,
                                             "classificationReview": report.items.filter(\.classificationNeedsReview).count,
                                             "subjects": Dictionary(grouping: report.items, by: \.subject)
                                                .mapValues(\.count),
                                             "versions": report.items.map { ["path": $0.relativePath,
                                                                               "version": $0.version] }]
                let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
                print(String(decoding: data, as: UTF8.self))
            } catch {
                fputs("Ravil Goodnotes preview failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
            return
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--goodnotes-ocr-preview") {
            guard CommandLine.arguments.indices.contains(flag + 2),
                  let page = Int(CommandLine.arguments[flag + 2]) else {
                fputs("usage: Ravil --goodnotes-ocr-preview <material-id> <page-number>\n", stderr)
                exit(2)
            }
            do {
                let result = try LibraryDatabase().previewGoodnotesOCR(
                    materialID: CommandLine.arguments[flag + 1], pageNumber: page)
                print("Ravil OCR preview: \(result.characters) characters, mean confidence \(String(format: "%.2f", result.confidence))")
            } catch {
                fputs("Ravil OCR preview failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
            return
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--goodnotes-ocr-material") {
            guard CommandLine.arguments.indices.contains(flag + 2),
                  let limit = Int(CommandLine.arguments[flag + 2]) else {
                fputs("usage: Ravil --goodnotes-ocr-material <material-id> <max-pages>\n", stderr)
                exit(2)
            }
            do {
                let report = try LibraryDatabase().runGoodnotesOCR(
                    limit: limit, materialID: CommandLine.arguments[flag + 1])
                let data = try JSONEncoder().encode(report)
                print(String(decoding: data, as: UTF8.self))
                if report.failed > 0 { exit(1) }
            } catch {
                fputs("Ravil material OCR failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
            return
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--goodnotes-ocr") {
            guard CommandLine.arguments.indices.contains(flag + 1),
                  let limit = Int(CommandLine.arguments[flag + 1]) else {
                fputs("usage: Ravil --goodnotes-ocr <max-pages>\n", stderr)
                exit(2)
            }
            do {
                let report = try LibraryDatabase().runGoodnotesOCR(limit: limit)
                let data = try JSONEncoder().encode(report)
                print(String(decoding: data, as: UTF8.self))
                if report.failed > 0 { exit(1) }
            } catch {
                fputs("Ravil OCR failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
            return
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--goodnotes-import-dry-run") {
            guard CommandLine.arguments.indices.contains(flag + 1) else {
                fputs("usage: Ravil --goodnotes-import-dry-run <manifest.json>\n", stderr)
                exit(2)
            }
            do {
                let folder = FileManager.default.temporaryDirectory
                    .appendingPathComponent("RavilGoodnotesDryRun-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: folder) }
                let database = try LibraryDatabase(location: folder.appendingPathComponent("library.sqlite"),
                                                   importLegacy: false)
                let manifestURL = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
                let report = try database.importGoodnotesMidterm(manifestURL: manifestURL)
                let summary: [String: Any] = ["imported": report.imported,
                                               "newVersions": report.newVersions,
                                               "visibleMaterials": try database.materials().count,
                                               "classificationReview": report.items.filter(\.classificationNeedsReview).count,
                                               "reviewPaths": report.items.filter(\.classificationNeedsReview)
                                                    .map(\.relativePath),
                                               "subjects": Dictionary(grouping: report.items, by: \.subject)
                                                    .mapValues(\.count)]
                let output = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
                print(String(decoding: output, as: UTF8.self))
            } catch {
                fputs("Ravil Goodnotes dry run failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
            return
        }
        if CommandLine.arguments.contains("--goodnotes-import-check") {
            do { try GoodnotesImportCheck.run() }
            catch {
                fputs("Ravil Goodnotes import check failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
            return
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--goodnotes-import") {
            guard CommandLine.arguments.indices.contains(flag + 1) else {
                fputs("usage: Ravil --goodnotes-import <manifest.json>\n", stderr)
                exit(2)
            }
            do {
                let manifestURL = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
                let database = try LibraryDatabase()
                let report = try database.importGoodnotesMidterm(manifestURL: manifestURL)
                let output = try JSONEncoder().encode(report)
                print(String(decoding: output, as: UTF8.self))
            } catch {
                fputs("Ravil Goodnotes import failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
            return
        }
        if CommandLine.arguments.contains("--alt-folders-check") {
            do {
                guard let snapshot = try AltFolderSnapshotReader.load() else {
                    throw DatabaseError.sqlite("Alt DSHS 폴더 저장소를 찾지 못했습니다")
                }
                let folder = FileManager.default.temporaryDirectory
                    .appendingPathComponent("RavilAltFolders-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: folder) }
                let database = try LibraryDatabase(location: folder.appendingPathComponent("library.sqlite"),
                                                   importLegacy: false)
                let sync = try database.syncAlt(from: snapshot.sourceURL)
                let lectures = try database.lectures()
                guard sync.discovered == snapshot.notes.count,
                      lectures.count == snapshot.notes.count else {
                    throw DatabaseError.sqlite("Alt 폴더의 노트 수와 임시 저장소 가져오기 결과가 다릅니다")
                }
                var folderCounts: [String: Int] = [:]
                for sourceFolder in snapshot.folders {
                    let imported = lectures.filter { $0.altFolderName == sourceFolder.name }.count
                    guard imported == sourceFolder.noteCount else {
                        throw DatabaseError.sqlite("Alt 폴더 '\(sourceFolder.name)' 노트 수가 다릅니다")
                    }
                    folderCounts[sourceFolder.name] = imported
                }
                let state: [String: Any] = [
                    "workspace": snapshot.workspaceName,
                    "sourceFolderCount": snapshot.folders.count,
                    "sourceNoteCount": snapshot.notes.count,
                    "importedNoteCount": lectures.count,
                    "folderCounts": folderCounts
                ]
                let output = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
                print(String(decoding: output, as: UTF8.self))
            } catch {
                fputs("Ravil Alt folder check failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
            return
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--transcription-contract-check") {
            guard CommandLine.arguments.indices.contains(flag + 1) else {
                fputs("usage: Ravil --transcription-contract-check <transcription.json>\n", stderr)
                exit(2)
            }
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
                let phrases = try JSONDecoder().decode(WhisperOutput.self, from: data).transcription
                guard !phrases.isEmpty,
                      phrases.allSatisfy({ $0.offsets.from >= 0 && $0.offsets.to >= $0.offsets.from
                          && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
                      zip(phrases, phrases.dropFirst()).allSatisfy({ pair in
                          pair.0.offsets.from <= pair.1.offsets.from
                      }) else {
                    throw DatabaseError.sqlite("전사 구간 또는 시각이 올바르지 않습니다")
                }
                print("Ravil transcription contract: \(phrases.count) timestamped phrases accepted")
            } catch {
                fputs("Ravil transcription contract failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
            return
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--transcription-check") {
            guard CommandLine.arguments.indices.contains(flag + 1) else {
                fputs("usage: Ravil --transcription-check <audio.wav> [auto|ko|en|ja|zh] [--vad]\n", stderr)
                exit(2)
            }
            do {
                let source = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
                let output = FileManager.default.temporaryDirectory
                    .appendingPathComponent("RavilTranscriptionCheck-\(UUID().uuidString)", isDirectory: true)
                defer { try? FileManager.default.removeItem(at: output) }
                let candidate = CommandLine.arguments.indices.contains(flag + 2)
                    ? CommandLine.arguments[flag + 2] : "auto"
                let language = candidate.hasPrefix("--") ? "auto" : candidate
                let phrases = try WhisperTranscriber(executable: AppPaths.whisperCLI,
                                                     model: AppPaths.preferredModel,
                                                     outputDirectory: output).transcribe(
                    audio: source,
                    options: TranscriptionOptions(language: language,
                                                  translateToEnglish: false,
                                                  keywordPrompt: "",
                                                  useVAD: CommandLine.arguments.contains("--vad")))
                guard !phrases.isEmpty, phrases.allSatisfy({ $0.offsets.to >= $0.offsets.from }) else {
                    throw DatabaseError.sqlite("타임스탬프가 포함된 전사 결과가 없습니다")
                }
                print("Ravil transcription check: \(phrases.count) timestamped phrases from bundled local model (\(language))")
            } catch {
                fputs("Ravil transcription check failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
            return
        }
        if CommandLine.arguments.contains("--smoke-test") {
            do {
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RavilSmoke-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: folder) }
                let audio = folder.appendingPathComponent("sample.wav")
                try Data([82, 73, 70, 70]).write(to: audio)
                let location = folder.appendingPathComponent("smoke.sqlite")
                let lectureID: String
                do {
                    let db = try LibraryDatabase(location: location, importLegacy: false)
                    try db.saveNote(KnowledgeNote(id: "smoke-note", title: "시간대 검산", body: "UTC를 확인한다", updatedAt: ""))
                    lectureID = try db.addRecording(title: "시험 강의", courseID: nil, audioURL: audio, startedAt: Date())
                    let sample = Data("""
                    {"transcription":[{"offsets":{"from":1200,"to":4300},"text":"오일러 방법"}]}
                    """.utf8)
                    let phrases = try JSONDecoder().decode(WhisperOutput.self, from: sample).transcription
                    try db.saveTranscript(phrases, for: lectureID)
                    try db.execute("PRAGMA journal_mode = WAL")
                }
                let migratedLocation = folder.appendingPathComponent("migrated.sqlite")
                try LibraryDatabase.backup(from: location, to: migratedLocation)
                let migrated = try LibraryDatabase(location: migratedLocation, importLegacy: false)
                guard try migrated.notes().count == 1,
                      try migrated.transcript(for: lectureID).count == 1 else {
                    throw DatabaseError.sqlite("SQLite 백업 후 데이터가 보존되지 않았습니다")
                }
                let reopened = try LibraryDatabase(location: location, importLegacy: false)
                let altFixture = folder.appendingPathComponent("alt.sqlite")
                do {
                    let fixture = try LibraryDatabase(location: altFixture, importLegacy: false)
                    try fixture.execute("CREATE TABLE lecture_notes (id TEXT PRIMARY KEY, title TEXT, lecture_date TEXT, status TEXT, deleted_at TEXT)")
                    try fixture.execute("CREATE TABLE note_components (id TEXT PRIMARY KEY, note_id TEXT, component_type TEXT, content_text TEXT, file_inode INTEGER, deleted_at TEXT)")
                    try fixture.execute("CREATE TABLE file_metadata (inode INTEGER PRIMARY KEY, file_path TEXT)")
                    try fixture.execute("INSERT INTO lecture_notes (id, title, lecture_date, status) VALUES ('alt-fixture', 'Alt 테스트', '2026-09-23', 'draft')")
                    let raw = "[{\"segments\":[{\"start\":0,\"end\":1800,\"text\":\"Alt 전사 첫 문장\",\"speaker\":\"\"}]}]"
                    try fixture.execute("INSERT INTO note_components (id, note_id, component_type, content_text) VALUES ('tx-fixture', 'alt-fixture', 'transcript', ?)", values: [raw])
                    try fixture.execute("PRAGMA journal_mode = WAL")
                }
                let firstSync = try reopened.syncAlt(from: altFixture)
                let repeatedSync = try reopened.syncAlt(from: altFixture)
                guard try reopened.notes().count == 1,
                      try reopened.lectures().count == 2,
                      try reopened.transcript(for: lectureID).first?.startMilliseconds == 1_200,
                      try reopened.search("오일러").contains(where: { $0.kind == .transcript }),
                      firstSync.imported == 1, repeatedSync.imported == 0,
                      try reopened.search("Alt 전사").contains(where: { $0.kind == .transcript }) else {
                    throw DatabaseError.sqlite("저장 후 재조회 결과가 다릅니다")
                }
                guard let altLecture = try reopened.lectures().first(where: { $0.title == "Alt 테스트" }),
                      let altSegmentID = try reopened.rows("SELECT id FROM transcript_segments WHERE lecture_id = ?", values: [altLecture.id]).first?["id"] else {
                    throw DatabaseError.sqlite("Alt 전사 세그먼트를 찾을 수 없습니다")
                }
                try reopened.execute("""
                INSERT INTO evidence (id, lecture_id, transcript_segment_id, kind, quote, start_ms, end_ms, pipeline_version)
                VALUES ('smoke-evidence', ?, ?, 'professor_emphasis', 'Alt 전사 첫 문장', 0, 1800, 'rules-v1')
                """, values: [altLecture.id, altSegmentID])
                try reopened.execute("""
                INSERT INTO ai_artifacts (id, lecture_id, artifact_type, pipeline_version, payload_json, created_at)
                VALUES ('smoke-intelligence', ?, 'lecture_intelligence', 'smoke-v1', '{"verification":{"evidenceReferencesValid":true}}', '2026-09-23T00:00:00Z')
                """, values: [altLecture.id])
                do {
                    let fixture = try LibraryDatabase(location: altFixture, importLegacy: false)
                    try fixture.execute("UPDATE lecture_notes SET title = 'Alt 제목 수정' WHERE id = 'alt-fixture'")
                }
                let titleSync = try reopened.syncAlt(from: altFixture)
                guard titleSync.imported == 1,
                      try reopened.rows("SELECT id FROM evidence WHERE id = 'smoke-evidence'").count == 1,
                      try reopened.rows("SELECT id FROM transcript_segments WHERE id = ?", values: [altSegmentID]).count == 1 else {
                    throw DatabaseError.sqlite("Alt 제목 수정 중 근거가 사라졌습니다")
                }
                do {
                    let fixture = try LibraryDatabase(location: altFixture, importLegacy: false)
                    let changed = "[{\"segments\":[{\"start\":0,\"end\":1800,\"text\":\"Alt 전사 수정 문장\",\"speaker\":\"\"}]}]"
                    try fixture.execute("UPDATE note_components SET content_text = ? WHERE id = 'tx-fixture'", values: [changed])
                }
                let changedSync = try reopened.syncAlt(from: altFixture)
                guard changedSync.imported == 1,
                      try reopened.rows("SELECT id FROM evidence WHERE id = 'smoke-evidence'").isEmpty,
                      try reopened.rows("SELECT id FROM ai_artifacts WHERE id = 'smoke-intelligence'").count == 1,
                      let rawArtifact = try reopened.rows("SELECT payload_json FROM ai_artifacts WHERE id = 'smoke-intelligence'").first?["payload_json"],
                      rawArtifact.contains("\"sourceChanged\":true") else {
                    throw DatabaseError.sqlite("Alt 원문 수정 후 근거 상태가 올바르지 않습니다")
                }
                try reopened.saveMemo("오일러 방법 다시 보기", for: lectureID)
                guard try reopened.memo(for: lectureID) == "오일러 방법 다시 보기" else {
                    throw DatabaseError.sqlite("강의별 노트가 저장되지 않았습니다")
                }
                let pdfURL = folder.appendingPathComponent("sample.pdf")
                var pageBox = CGRect(x: 0, y: 0, width: 150, height: 180)
                guard let consumer = CGDataConsumer(url: pdfURL as CFURL),
                      let context = CGContext(consumer: consumer, mediaBox: &pageBox, nil) else {
                    throw DatabaseError.sqlite("테스트 PDF를 만들 수 없습니다")
                }
                context.beginPDFPage(nil)
                context.setFillColor(NSColor.white.cgColor)
                context.fill(pageBox)
                context.endPDFPage()
                context.closePDF()
                guard PDFDocument(url: pdfURL)?.pageCount == 1 else {
                    throw DatabaseError.sqlite("테스트 PDF가 유효하지 않습니다")
                }
                let material = try reopened.importLocalPDF(from: pdfURL, courseID: nil)
                let duplicate = try reopened.importLocalPDF(from: pdfURL, courseID: nil)
                guard material.id == duplicate.id, material.pageCount == 1,
                      let path = material.localPath, FileManager.default.fileExists(atPath: path) else {
                    throw DatabaseError.sqlite("PDF 보관 또는 중복 검사가 실패했습니다")
                }
                guard let previousSegmentID = try reopened.transcript(for: lectureID).first?.id else {
                    throw DatabaseError.sqlite("재전사 전 구간을 찾지 못했습니다")
                }
                try reopened.execute("""
                    INSERT INTO evidence (id, lecture_id, transcript_segment_id, kind, quote, start_ms, end_ms, pipeline_version)
                    VALUES ('ravil-old-evidence', ?, ?, 'source_quote', '오일러 방법', 1200, 4300, 'fixture-v1')
                    """, values: [lectureID, previousSegmentID])
                let revisedSample = Data("""
                    {"transcription":[{"offsets":{"from":1000,"to":4000},"text":"Astronomy practice"}]}
                    """.utf8)
                let revisedPhrases = try JSONDecoder().decode(WhisperOutput.self, from: revisedSample).transcription
                try reopened.saveTranscript(revisedPhrases, for: lectureID,
                                            options: TranscriptionOptions(language: "en",
                                                                          translateToEnglish: false,
                                                                          keywordPrompt: ""),
                                            modelID: "fixture-model")
                guard try reopened.transcript(for: lectureID).map(\.text) == ["Astronomy practice"],
                      try reopened.search("오일러").contains(where: { $0.kind == .transcript && $0.targetID == lectureID }) == false,
                      try reopened.search("Astronomy practice").contains(where: { $0.kind == .transcript && $0.targetID == lectureID }),
                      try reopened.rows("SELECT id FROM transcript_segments WHERE id = ?",
                                        values: [previousSegmentID]).count == 1,
                      try reopened.rows("SELECT id FROM evidence WHERE id = 'ravil-old-evidence'").count == 1,
                      try reopened.rows("SELECT segment_id FROM transcript_superseded_segments WHERE segment_id = ?",
                                        values: [previousSegmentID]).count == 1,
                      try reopened.lectures().first(where: { $0.id == lectureID })?.canTranscribe == true else {
                    throw DatabaseError.sqlite("재전사 후 이전 구간 보존 또는 최신 검색 검사가 실패했습니다")
                }
                do {
                    try reopened.saveTranscript([], for: lectureID)
                    throw DatabaseError.sqlite("빈 재전사 결과가 수락됐습니다")
                } catch {
                    guard error.localizedDescription.contains("비어 있거나") else { throw error }
                }
                print("Ravil smoke test: database, notes, recording, transcript, Alt sync, memo, and PDF passed")
            } catch {
                fputs("Ravil smoke test failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
            return
        }
        if CommandLine.arguments.contains("--self-check") {
            do {
                let database = try LibraryDatabase()
                let folderSnapshot = try AltFolderSnapshotReader.load()
                let sync = try folderSnapshot.map { try database.syncAlt(from: $0.sourceURL) }
                    ?? AltSyncResult(discovered: 0, imported: 0, unchanged: 0)
                let activeModel = URL(fileURLWithPath: AppPaths.resolvedModelPath(
                    saved: UserDefaults.standard.string(forKey: "RavilWhisperModelPath")))
                let activeEngine = URL(fileURLWithPath: AppPaths.resolvedWhisperCLIPath(
                    saved: UserDefaults.standard.string(forKey: "RavilWhisperExecutablePath")))
                let state: [String: Any] = [
                    "databaseReady": true,
                    "lectureCount": try database.lectures().count,
                    "courseCount": try database.courses().count,
                    "materialCount": try database.materials().count,
                    "noteCount": try database.notes().count,
                    "altDiscovered": sync.discovered,
                    "altNewImports": sync.imported,
                    "altWorkspace": folderSnapshot?.workspaceName ?? "unavailable",
                    "altFolderCount": folderSnapshot?.folders.count ?? 0,
                    "localModelReady": WhisperTranscriber(executable: activeEngine,
                                                          model: activeModel).isAvailable,
                    "modelSource": (AppPaths.bundledModel.map { $0.path == activeModel.path } ?? false) ? "bundled" : "external",
                    "engineSource": (AppPaths.bundledWhisperCLI.map { $0.path == activeEngine.path } ?? false) ? "bundled" : "external"
                ]
                let output = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
                print(String(decoding: output, as: UTF8.self))
            } catch {
                fputs("Ravil self-check failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
            return
        }
        RavilApp.main()
    }
}

struct RavilApp: App {
    @State private var model = AppModel()
    @AppStorage("RavilDarkAppearance") private var darkAppearance = true

    var body: some Scene {
        WindowGroup("Ravil") {
            ContentView(model: model)
                .frame(minWidth: 980, minHeight: 680)
                .preferredColorScheme(darkAppearance ? .dark : nil)
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("새 노트") {
                    model.section = .notes
                    model.selectedNoteID = nil
                }
                .keyboardShortcut("n")
                Button("녹음 화면") { model.section = .capture }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }
}
