import AppKit
import Foundation
import PDFKit
import Vision

struct GoodnotesOCRReport: Encodable {
    let attempted: Int
    let recognized: Int
    let noText: Int
    let failed: Int
}

private struct GoodnotesOCRCandidate {
    let pageID: String
    let materialID: String
    let pageNumber: Int
    let localPath: String
}

private struct GoodnotesOCRResult {
    let text: String
    let meanConfidence: Double
}

private enum GoodnotesTextRecognizer {
    static let engineVersion = "apple-vision-accurate-ko-en-v1"

    static func recognize(pdfPath: String, pageNumber: Int) throws -> GoodnotesOCRResult {
        let url = URL(fileURLWithPath: pdfPath)
        guard let pdf = PDFDocument(url: url),
              let page = pdf.page(at: pageNumber - 1) else {
            throw DatabaseError.sqlite("OCR 대상 PDF 페이지를 열 수 없습니다")
        }
        let image = page.thumbnail(of: NSSize(width: 1800, height: 2400), for: .mediaBox)
        var imageRect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &imageRect, context: nil, hints: nil) else {
            throw DatabaseError.sqlite("OCR 대상 페이지 이미지를 만들 수 없습니다")
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ko-KR", "en-US"]
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])
        let lines = (request.results ?? []).sorted { lhs, rhs in
            if abs(lhs.boundingBox.midY - rhs.boundingBox.midY) > 0.012 {
                return lhs.boundingBox.midY > rhs.boundingBox.midY
            }
            return lhs.boundingBox.minX < rhs.boundingBox.minX
        }.compactMap { $0.topCandidates(1).first }
        let text = lines.map(\.string).joined(separator: "\n")
        let confidence = lines.isEmpty ? 0 : lines.reduce(0.0) { $0 + Double($1.confidence) } / Double(lines.count)
        return GoodnotesOCRResult(text: text, meanConfidence: confidence)
    }
}

extension LibraryDatabase {
    func runGoodnotesOCR(limit: Int, materialID: String? = nil) throws -> GoodnotesOCRReport {
        guard (1...1000).contains(limit) else { throw DatabaseError.sqlite("OCR 페이지 제한은 1~1000이어야 합니다") }
        let materialFilter = materialID == nil ? "" : "AND p.material_id = ?"
        let values: [String?] = materialID.map { [$0, String(limit)] } ?? [String(limit)]
        let candidates = try rows("""
            SELECT p.id AS page_id, p.material_id, p.page_number, m.local_path
            FROM material_pages p
            JOIN course_materials m ON m.id = p.material_id
            JOIN goodnotes_documents d ON d.current_material_id = m.id
            LEFT JOIN material_page_ocr o ON o.page_id = p.id
            WHERE o.page_id IS NULL AND length(trim(p.text)) < 20
              AND d.document_kind <> '빈 템플릿'
              \(materialFilter)
            ORDER BY d.subject, d.relative_path, p.page_number
            LIMIT ?
            """, values: values).compactMap { row -> GoodnotesOCRCandidate? in
                guard let id = row["page_id"], let materialID = row["material_id"],
                      let pageNumber = row["page_number"].flatMap(Int.init),
                      let path = row["local_path"] else { return nil }
                return GoodnotesOCRCandidate(pageID: id, materialID: materialID,
                                             pageNumber: pageNumber, localPath: path)
            }
        var recognized = 0
        var noText = 0
        var failed = 0
        for (index, candidate) in candidates.enumerated() {
            try Task.checkCancellation()
            do {
                let result = try GoodnotesTextRecognizer.recognize(pdfPath: candidate.localPath,
                                                                   pageNumber: candidate.pageNumber)
                let status = result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "no_text" : "needs_review"
                try execute("""
                    INSERT INTO material_page_ocr
                      (page_id, text, mean_confidence, status, engine_version, processed_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """, values: [candidate.pageID, result.text, String(result.meanConfidence), status,
                                  GoodnotesTextRecognizer.engineVersion,
                                  ISO8601DateFormatter().string(from: Date())])
                if status == "no_text" { noText += 1 } else { recognized += 1 }
            } catch {
                failed += 1
                fputs("Ravil OCR page \(candidate.materialID):\(candidate.pageNumber) failed: \(error.localizedDescription)\n", stderr)
            }
            if (index + 1) % 10 == 0 { fputs("Ravil OCR progress: \(index + 1)/\(candidates.count)\n", stderr) }
        }
        return GoodnotesOCRReport(attempted: candidates.count, recognized: recognized,
                                  noText: noText, failed: failed)
    }

    func previewGoodnotesOCR(materialID: String, pageNumber: Int) throws -> (characters: Int, confidence: Double) {
        guard let row = try rows("""
            SELECT m.local_path FROM course_materials m
            JOIN goodnotes_documents d ON d.current_material_id = m.id
            WHERE m.id = ? AND d.document_kind <> '빈 템플릿'
            """, values: [materialID]).first,
              let path = row["local_path"] else {
            throw DatabaseError.sqlite("현재 Goodnotes PDF를 찾지 못했습니다")
        }
        let result = try GoodnotesTextRecognizer.recognize(pdfPath: path, pageNumber: pageNumber)
        return (result.text.count, result.meanConfidence)
    }
}
