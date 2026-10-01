import Foundation
import PDFKit
import CryptoKit

struct GoodnotesImportManifest: Decodable {
    let midtermRootFolderID: String
    let entries: [GoodnotesImportEntry]
}

struct GoodnotesImportEntry: Decodable {
    let driveFileID: String
    let revisionID: String?
    let relativePath: String
    let localPDFPath: String
    let sourceURL: String
    let sourceModifiedAt: String?
    let subject: String?
    let documentKind: String?
}

struct GoodnotesImportReport: Encodable {
    struct Item: Encodable {
        let relativePath: String
        let documentID: String
        let materialID: String
        let version: Int
        let createdVersion: Bool
        let current: Bool
        let subject: String
        let documentKind: String
        let classificationNeedsReview: Bool
        let classificationSource: String
    }

    let midtermRootFolderID: String
    let imported: Int
    let newVersions: Int
    let unchanged: Int
    let items: [Item]
}

private struct PreparedGoodnotesPDF {
    let entry: GoodnotesImportEntry
    let relativePath: String
    let pathKey: String
    let sourceURL: String
    let contentHash: String
    let storedURL: URL
    let pageTexts: [String]
    let hasTextLayer: Bool
    let classification: GoodnotesClassification
}

extension LibraryDatabase {
    struct GoodnotesObservedSource {
        let revision: String?
        let relativePath: String
    }

    func goodnotesObservedSources(rootFolderID: String) throws -> [String: GoodnotesObservedSource] {
        let records = try rows("""
            SELECT drive_file_id, revision_id, relative_path
            FROM goodnotes_source_observations
            WHERE midterm_root_folder_id = ?
            ORDER BY rowid DESC
            """, values: [rootFolderID])
        var latest: [String: GoodnotesObservedSource] = [:]
        for record in records {
            guard let id = record["drive_file_id"], latest[id] == nil,
                  let path = record["relative_path"] else { continue }
            latest[id] = GoodnotesObservedSource(revision: record["revision_id"], relativePath: path)
        }
        return latest
    }

    func importGoodnotesMidterm(manifestURL: URL) throws -> GoodnotesImportReport {
        let manifest = try JSONDecoder().decode(GoodnotesImportManifest.self, from: Data(contentsOf: manifestURL))
        return try importGoodnotesMidterm(manifest)
    }

    func importGoodnotesMidterm(_ manifest: GoodnotesImportManifest) throws -> GoodnotesImportReport {
        let rootID = manifest.midtermRootFolderID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isDriveID(rootID) else {
            throw DatabaseError.sqlite("중간고사 루트 폴더 ID가 유효하지 않습니다")
        }
        guard !manifest.entries.isEmpty else {
            throw DatabaseError.sqlite("중간고사 PDF 목록이 비어 있습니다")
        }

        // Validate the whole snapshot before reading or writing any PDF. Drive permits
        // duplicate names; merging two entries with the same relative path would lose identity.
        var seenPaths = Set<String>()
        var seenFileIDs = Set<String>()
        var normalized: [(GoodnotesImportEntry, String, String, String)] = []
        for entry in manifest.entries {
            let relativePath = try Self.normalizedRelativePath(entry.relativePath)
            let pathKey = relativePath.lowercased(with: Locale(identifier: "en_US_POSIX"))
            guard seenPaths.insert(pathKey).inserted else {
                throw DatabaseError.sqlite("중복된 중간고사 상대 경로가 있습니다: \(relativePath)")
            }
            guard Self.isDriveID(entry.driveFileID), seenFileIDs.insert(entry.driveFileID).inserted else {
                throw DatabaseError.sqlite("Drive 파일 ID가 유효하지 않거나 목록에 중복되었습니다")
            }
            if let subject = entry.subject, !GoodnotesClassifier.allowedSubjects.contains(subject) {
                throw DatabaseError.sqlite("지원하지 않는 과목입니다: \(subject)")
            }
            if let kind = entry.documentKind {
                let cleaned = kind.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty, cleaned.count <= 80,
                      cleaned.rangeOfCharacter(from: .controlCharacters) == nil else {
                    throw DatabaseError.sqlite("자료 종류가 비어 있거나 유효하지 않습니다")
                }
            }
            guard let sourceURL = URL(string: entry.sourceURL),
                  sourceURL.scheme?.lowercased() == "https",
                  ["drive.google.com", "docs.google.com"].contains(sourceURL.host?.lowercased() ?? "") else {
                throw DatabaseError.sqlite("Drive 원본 URL이 유효하지 않습니다")
            }
            let urlFileIDMatches = sourceURL.pathComponents.contains(entry.driveFileID)
                || (URLComponents(url: sourceURL, resolvingAgainstBaseURL: false)?.queryItems?
                    .contains(where: { $0.name == "id" && $0.value == entry.driveFileID }) ?? false)
            guard urlFileIDMatches else {
                throw DatabaseError.sqlite("Drive 원본 URL과 파일 ID가 일치하지 않습니다")
            }
            guard entry.localPDFPath.hasPrefix("/") else {
                throw DatabaseError.sqlite("다운로드된 PDF의 절대 경로가 필요합니다")
            }
            normalized.append((entry, relativePath, pathKey, sourceURL.absoluteString))
        }

        // All bytes are copied and parsed before the database transaction. A failed PDF
        // therefore cannot replace any document's current version.
        let prepared = try normalized.map { item -> PreparedGoodnotesPDF in
            let source = URL(fileURLWithPath: item.0.localPDFPath).standardizedFileURL.resolvingSymlinksInPath()
            let values = try source.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else {
                throw DatabaseError.sqlite("일반 PDF 파일만 가져올 수 있습니다: \(item.1)")
            }
            let hash = try Self.goodnotesSHA256(of: source)
            let directory = location.deletingLastPathComponent().appendingPathComponent("Materials", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: directory.path)
            let stored = directory.appendingPathComponent("\(hash).pdf")
            if FileManager.default.fileExists(atPath: stored.path) {
                guard try Self.goodnotesSHA256(of: stored) == hash else {
                    throw DatabaseError.sqlite("보관된 PDF의 해시가 다릅니다: \(item.1)")
                }
            } else {
                let temporary = directory.appendingPathComponent(".\(UUID().uuidString).pdf")
                defer { try? FileManager.default.removeItem(at: temporary) }
                try FileManager.default.copyItem(at: source, to: temporary)
                guard try Self.goodnotesSHA256(of: temporary) == hash else {
                    throw DatabaseError.sqlite("PDF를 복사하는 동안 내용이 변경되었습니다: \(item.1)")
                }
                try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: temporary.path)
                if FileManager.default.fileExists(atPath: stored.path) {
                    guard try Self.goodnotesSHA256(of: stored) == hash else {
                        throw DatabaseError.sqlite("동시에 저장된 PDF의 해시가 다릅니다: \(item.1)")
                    }
                } else {
                    try FileManager.default.moveItem(at: temporary, to: stored)
                }
            }
            guard let pdf = PDFDocument(url: stored), pdf.pageCount > 0, !pdf.isEncrypted else {
                throw DatabaseError.sqlite("PDF를 읽을 수 없거나 암호로 보호되어 있습니다: \(item.1)")
            }
            let pages = (0..<pdf.pageCount).map { pdf.page(at: $0)?.string ?? "" }
            let classification = try GoodnotesClassifier.classify(
                relativePath: item.1, firstPageText: pages.first ?? "", pageCount: pages.count,
                suppliedSubject: item.0.subject, suppliedKind: item.0.documentKind)
            return PreparedGoodnotesPDF(entry: item.0, relativePath: item.1, pathKey: item.2,
                                        sourceURL: item.3, contentHash: hash, storedURL: stored,
                                        pageTexts: pages,
                                        hasTextLayer: pages.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
                                        classification: classification)
        }

        try execute("BEGIN IMMEDIATE")
        do {
            let now = ISO8601DateFormatter().string(from: Date())
            var items: [GoodnotesImportReport.Item] = []
            var seenDocuments = Set<String>()
            for pdf in prepared {
                let item = try importPreparedGoodnotesPDF(pdf, rootID: rootID, observedAt: now)
                guard seenDocuments.insert(item.documentID).inserted else {
                    throw DatabaseError.sqlite("한 굿노트 문서가 목록에 여러 번 나타납니다: \(pdf.relativePath)")
                }
                items.append(item)
            }
            try execute("COMMIT")
            let newVersions = items.filter(\.createdVersion).count
            return GoodnotesImportReport(midtermRootFolderID: rootID, imported: items.count,
                                         newVersions: newVersions, unchanged: items.count - newVersions,
                                         items: items)
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func importPreparedGoodnotesPDF(_ pdf: PreparedGoodnotesPDF, rootID: String,
                                            observedAt: String) throws -> GoodnotesImportReport.Item {
        let aliases = try rows("""
            SELECT DISTINCT document_id FROM goodnotes_source_observations
            WHERE midterm_root_folder_id = ? AND drive_file_id = ?
            """, values: [rootID, pdf.entry.driveFileID])
        guard aliases.count <= 1 else {
            throw DatabaseError.sqlite("Drive 파일 ID가 여러 문서에 연결되어 있습니다")
        }
        let aliasID = aliases.first?["document_id"]
        let paths = try rows("""
            SELECT id FROM goodnotes_documents
            WHERE midterm_root_folder_id = ? AND path_key = ?
            """, values: [rootID, pdf.pathKey])
        let pathID = paths.first?["id"]
        if let aliasID, let pathID, aliasID != pathID {
            throw DatabaseError.sqlite("Drive 파일 ID와 상대 경로가 서로 다른 문서를 가리킵니다: \(pdf.relativePath)")
        }
        let documentID = aliasID ?? pathID ?? UUID().uuidString
        let oldDocument = try rows("SELECT subject, document_kind FROM goodnotes_documents WHERE id = ?",
                                   values: [documentID]).first
        let oldClassification = try rows("""
            SELECT subject_source, kind_source, teacher_name, confidence
            FROM goodnotes_classifications WHERE document_id = ?
            """, values: [documentID]).first
        var subject = pdf.classification.subject
        var kind = pdf.classification.documentKind
        var subjectSource = pdf.classification.subjectSource
        var kindSource = pdf.classification.kindSource
        var classificationConflict = false
        if pdf.entry.subject == nil, let previous = oldDocument?["subject"],
           GoodnotesClassifier.allowedSubjects.contains(previous),
           oldClassification == nil || ["provided", "manual"].contains(oldClassification?["subject_source"] ?? "")
              || subject == GoodnotesClassifier.unclassifiedSubject {
            if subject != GoodnotesClassifier.unclassifiedSubject && subject != previous,
               oldClassification?["subject_source"] != "manual" {
                classificationConflict = true
            }
            subject = previous
            subjectSource = oldClassification?["subject_source"] ?? "provided"
        }
        if pdf.entry.documentKind == nil, let previous = oldDocument?["document_kind"],
           Self.validGoodnotesKind(previous),
           oldClassification == nil || ["provided", "manual"].contains(oldClassification?["kind_source"] ?? "")
              || kind == GoodnotesClassifier.unclassifiedKind {
            kind = previous
            kindSource = oldClassification?["kind_source"] ?? "provided"
        }
        let needsReview = classificationConflict
            || subject == GoodnotesClassifier.unclassifiedSubject
            || kind == GoodnotesClassifier.unclassifiedKind
            || subjectSource == "first_page"
            || (pdf.classification.needsReview && subjectSource != "manual" && kindSource != "manual")
        let hasManualChoice = subjectSource == "manual" || kindSource == "manual"
        let teacher = hasManualChoice ? oldClassification?["teacher_name"]
            : pdf.classification.teacherName ?? oldClassification?["teacher_name"]
        let confidence = hasManualChoice
            ? oldClassification?["confidence"].flatMap(Double.init) ?? 1
            : subjectSource == "provided" ? 1 : pdf.classification.confidence
        if aliasID == nil && pathID == nil {
            try execute("""
                INSERT INTO goodnotes_documents
                  (id, midterm_root_folder_id, relative_path, path_key, subject, document_kind,
                   current_material_id, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, NULL, ?, ?)
            """, values: [documentID, rootID, pdf.relativePath, pdf.pathKey,
                              subject, kind, observedAt, observedAt])
        } else {
            try execute("""
                UPDATE goodnotes_documents
                SET relative_path = ?, path_key = ?, subject = ?, document_kind = ?, updated_at = ?
                WHERE id = ?
            """, values: [pdf.relativePath, pdf.pathKey, subject, kind,
                              observedAt, documentID])
        }
        try execute("""
            INSERT INTO goodnotes_classifications
              (document_id, subject_source, kind_source, teacher_name, confidence,
               needs_review, classified_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(document_id) DO UPDATE SET
              subject_source = excluded.subject_source,
              kind_source = excluded.kind_source,
              teacher_name = excluded.teacher_name,
              confidence = excluded.confidence,
              needs_review = excluded.needs_review,
              classified_at = excluded.classified_at
            """, values: [documentID, subjectSource, kindSource, teacher,
                          String(confidence),
                          needsReview ? "1" : "0", observedAt])

        let existing = try rows("""
            SELECT material_id, version FROM goodnotes_versions
            WHERE document_id = ? AND content_hash = ?
            """, values: [documentID, pdf.contentHash]).first
        let materialID: String
        let version: Int
        let created: Bool
        if let existing, let oldMaterialID = existing["material_id"],
           let oldVersion = existing["version"].flatMap(Int.init) {
            materialID = oldMaterialID
            version = oldVersion
            created = false
        } else {
            let previous = try rows("""
                SELECT MAX(version) AS version FROM goodnotes_versions WHERE document_id = ?
                """, values: [documentID]).first?["version"].flatMap(Int.init) ?? 0
            version = previous + 1
            materialID = UUID().uuidString
            created = true
            try execute("""
                INSERT INTO course_materials
                  (id, course_id, lecture_id, provider, external_id, external_url,
                   file_name, mime_type, local_path, content_hash, source_modified_at,
                   version, page_count, has_text_layer, status, ingested_at)
                VALUES (?, NULL, NULL, 'goodnotes_drive_pdf', ?, ?, ?, 'application/pdf', ?, ?, ?, ?, ?, ?, 'ingested', ?)
                """, values: [materialID, pdf.entry.driveFileID, pdf.sourceURL,
                              (pdf.relativePath as NSString).lastPathComponent, pdf.storedURL.path,
                              pdf.contentHash, pdf.entry.sourceModifiedAt, String(version),
                              String(pdf.pageTexts.count), pdf.hasTextLayer ? "1" : "0", observedAt])
            for (index, text) in pdf.pageTexts.enumerated() {
                let textHash = Self.goodnotesSHA256(of: Data(text.utf8))
                try execute("""
                    INSERT INTO material_pages (id, material_id, page_number, text, text_hash)
                    VALUES (?, ?, ?, ?, ?)
                    """, values: [UUID().uuidString, materialID, String(index + 1), text, textHash])
            }
            try execute("""
                INSERT INTO goodnotes_versions (material_id, document_id, version, content_hash)
                VALUES (?, ?, ?, ?)
                """, values: [materialID, documentID, String(version), pdf.contentHash])
        }

        let current = try rows("""
            SELECT v.version FROM goodnotes_documents d
            LEFT JOIN goodnotes_versions v ON v.material_id = d.current_material_id
            WHERE d.id = ?
            """, values: [documentID]).first?["version"].flatMap(Int.init) ?? 0
        if version >= current {
            try execute("UPDATE goodnotes_documents SET current_material_id = ?, updated_at = ? WHERE id = ?",
                        values: [materialID, observedAt, documentID])
        }
        // A rename changes the document label even when the PDF bytes did not change.
        let currentMaterialID = try rows("SELECT current_material_id FROM goodnotes_documents WHERE id = ?",
                                         values: [documentID]).first?["current_material_id"]
        if let currentMaterialID {
            try execute("UPDATE course_materials SET file_name = ? WHERE id = ?",
                        values: [(pdf.relativePath as NSString).lastPathComponent, currentMaterialID])
        }

        let observationPayload = [rootID, pdf.entry.driveFileID, pdf.entry.revisionID ?? "",
                                  pdf.relativePath, pdf.sourceURL,
                                  pdf.entry.sourceModifiedAt ?? "", pdf.contentHash]
            .joined(separator: "\u{1F}")
        let observationKey = Self.goodnotesSHA256(of: Data(observationPayload.utf8))
        try execute("""
            INSERT OR IGNORE INTO goodnotes_source_observations
              (observation_key, document_id, material_id, midterm_root_folder_id, drive_file_id,
               revision_id, relative_path, source_url, source_modified_at, observed_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, values: [observationKey, documentID, materialID, rootID,
                          pdf.entry.driveFileID, pdf.entry.revisionID, pdf.relativePath,
                          pdf.sourceURL, pdf.entry.sourceModifiedAt, observedAt])
        return GoodnotesImportReport.Item(relativePath: pdf.relativePath, documentID: documentID,
                                          materialID: materialID, version: version,
                                          createdVersion: created, current: currentMaterialID == materialID,
                                          subject: subject, documentKind: kind,
                                          classificationNeedsReview: needsReview,
                                          classificationSource: subjectSource)
    }

    private static func normalizedRelativePath(_ raw: String) throws -> String {
        let path = raw.precomposedStringWithCanonicalMapping
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasSuffix("/"),
              path.rangeOfCharacter(from: .controlCharacters) == nil,
              !path.contains("\\"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              (components.last?.lowercased().hasSuffix(".pdf") ?? false) else {
            throw DatabaseError.sqlite("중간고사 루트 기준의 안전한 PDF 상대 경로가 필요합니다: \(raw)")
        }
        return path
    }

    private static func isDriveID(_ value: String) -> Bool {
        !value.isEmpty && value.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
    }

    private static func goodnotesSHA256(of url: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hasher = SHA256()
        while true {
            let chunk = try input.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func goodnotesSHA256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
