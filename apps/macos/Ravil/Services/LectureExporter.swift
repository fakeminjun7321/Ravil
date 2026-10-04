import Foundation
import CoreText
import CoreGraphics

enum LectureExportFormat: String, CaseIterable, Identifiable {
    case markdown = "Markdown", pdf = "PDF", srt = "SRT 자막", vtt = "WebVTT 자막", audio = "원본 녹음"
    var id: String { rawValue }
    var suffix: String { switch self { case .markdown: return "md"; case .pdf: return "pdf"; case .srt: return "srt"; case .vtt: return "vtt"; case .audio: return "wav" } }
}
enum LectureExporter {
    static func timestamp(_ ms: Int, separator: String = ",") -> String {
        let n = max(0, ms)
        return String(format: "%02d:%02d:%02d%@%03d", n / 3600000, n / 60000 % 60, n / 1000 % 60, separator, n % 1000)
    }
    static func text(title: String, memo: String, segments: [TranscriptItem], bookmarks: [LectureBookmark], format: LectureExportFormat) -> String {
        if format == .srt || format == .vtt {
            let separator = format == .vtt ? "." : ","
            return (format == .vtt ? "WEBVTT\n\n" : "") + segments.enumerated().map { index, s in
                let content = (s.speaker.map { "\($0): " } ?? "") + s.text
                    .replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
                let escaped = content.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
                return "\(index+1)\n\(timestamp(s.startMilliseconds, separator: separator)) --> \(timestamp(max(s.startMilliseconds+1,s.endMilliseconds), separator: separator))\n\(escaped)\n"
            }.joined(separator: "\n")
        }
        return "# \(title)\n\n## 내 노트\n\n\(memo)\n\n## 중요 구간\n\n" + bookmarks.map {
            "- \(timestamp($0.milliseconds))\($0.page.map { " · PDF \($0)쪽" } ?? "") — \($0.note)"
        }.joined(separator: "\n") + "\n\n## 전사\n\n" + segments.map {
            "[\(timestamp($0.startMilliseconds))]\($0.speaker.map { " \($0)" } ?? "") \($0.text)"
        }.joined(separator: "\n\n") + "\n"
    }
    static func pdf(_ text: String, to url: URL) throws {
        var bounds = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(url: url as CFURL), let context = CGContext(consumer: consumer, mediaBox: &bounds, nil) else { throw DatabaseError.sqlite("PDF 파일을 만들 수 없습니다") }
        let font = CTFontCreateWithName("AppleSDGothicNeo-Regular" as CFString, 11, nil)
        let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let setter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: bounds.insetBy(dx: 42, dy: 45), transform: nil)
        var offset = 0
        repeat {
            context.beginPDFPage(nil)
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: offset, length: 0), path, nil)
            CTFrameDraw(frame, context)
            let range = CTFrameGetVisibleStringRange(frame)
            context.endPDFPage()
            guard range.length > 0 else { break }
            offset += range.length
        } while offset < attributed.length
        context.closePDF()
    }
}
