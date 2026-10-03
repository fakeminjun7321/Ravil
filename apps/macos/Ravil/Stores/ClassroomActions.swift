import Foundation
import AppKit
import UniformTypeIdentifiers

extension AppModel {
    func addBookmark(lectureID: String, note: String = "중요") {
        let ms = Int((isRecording && activeLectureID == lectureID ? recordingElapsed : playbackPosition) * 1000)
        do {
            try database?.saveBookmark(LectureBookmark(lectureID: lectureID, milliseconds: ms,
                materialID: classroomMaterialID, page: classroomMaterialID == nil ? nil : classroomPage, note: note))
            lectureBookmarks = try database?.bookmarks(for: lectureID) ?? []
        } catch { alert = error.localizedDescription }
    }
    func updateBookmark(_ bookmark: LectureBookmark, note: String) {
        var edited = bookmark; edited.note = note
        do { try database?.saveBookmark(edited); lectureBookmarks = try database?.bookmarks(for: bookmark.lectureID) ?? [] }
        catch { alert = error.localizedDescription }
    }
    func openBookmark(_ b: LectureBookmark) {
        if let id = b.materialID { ensureReferenceMaterial(id) }
        selectLecture(b.lectureID)
        classroomMaterialID = b.materialID; classroomPage = b.page ?? 1
        if !isRecording { play(at: b.milliseconds) }
    }
    func editTranscript(_ segment: TranscriptItem, text: String, speaker: String?) {
        do {
            try database?.editTranscript(segmentID: segment.id, text: text, speaker: speaker)
            if let id = selectedLectureID { transcript = try database?.transcript(for: id) ?? [] }
            updateSearch()
        } catch { alert = error.localizedDescription }
    }
    func renameSpeaker(_ old: String, to new: String, lectureID: String) {
        do { try database?.renameSpeaker(lectureID: lectureID, old: old, new: new); transcript = try database?.transcript(for: lectureID) ?? [] }
        catch { alert = error.localizedDescription }
    }
    func separateSpeakers(lecture: LectureItem, count: Int) {
        guard !isSeparatingSpeakers, let path = lecture.audioPath else { return }
        isSeparatingSpeakers = true
        let segments = transcript
        Task {
            defer { isSeparatingSpeakers = false }
            let result = await Task.detached(priority: .utility) { Result { try SpeakerDiarizer.cluster(audio: URL(fileURLWithPath: path), segments: segments, count: count) } }.value
            do {
                let labels = try result.get()
                for s in segments where labels[s.id] != nil {
                    // A user may edit while analysis runs. Never overwrite that newer edit.
                    guard let current = try database?.rows("SELECT text, speaker_id FROM transcript_segments WHERE id = ?", values: [s.id]).first,
                          current["text"] == s.text, current["speaker_id"] == s.speaker else { continue }
                    try database?.editTranscript(segmentID: s.id, text: s.text, speaker: labels[s.id])
                }
                if selectedLectureID == lecture.id { transcript = try database?.transcript(for: lecture.id) ?? [] }
            } catch { alert = error.localizedDescription }
        }
    }
    func exportLecture(_ lecture: LectureItem, format: LectureExportFormat) {
        guard let database else { return }
        do {
            let segments = try database.transcript(for: lecture.id)
            let bookmarks = try database.bookmarks(for: lecture.id)
            let memo = try pendingLectureMemos[lecture.id] ?? database.memo(for: lecture.id)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: format == .audio ? (lecture.audioPath.map { URL(fileURLWithPath: $0).pathExtension } ?? "wav") : format.suffix) ?? .data]
            panel.nameFieldStringValue = String(lecture.title.map { "/:\\".contains($0) ? "_" : $0 }.prefix(100)) + "." + (panel.allowedContentTypes.first?.preferredFilenameExtension ?? format.suffix)
            guard panel.runModal() == .OK, let url = panel.url else { return }
            if format == .audio {
                guard let source = lecture.audioPath else { throw DatabaseError.sqlite("원본 녹음이 없습니다") }
                let sourceURL = URL(fileURLWithPath: source)
                guard sourceURL.standardizedFileURL != url.standardizedFileURL else { throw DatabaseError.sqlite("원본과 다른 위치를 선택해 주세요") }
                // Save-panel overwrite consent applies only to the chosen output file.
                let staged = url.deletingLastPathComponent().appendingPathComponent(".ravil-export-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: staged) }
                try FileManager.default.copyItem(at: sourceURL, to: staged)
                if FileManager.default.fileExists(atPath: url.path) { _ = try FileManager.default.replaceItemAt(url, withItemAt: staged) }
                else { try FileManager.default.moveItem(at: staged, to: url) }
            } else {
                let content = LectureExporter.text(title: lecture.title, memo: memo, segments: segments, bookmarks: bookmarks, format: format)
                if format == .pdf { try LectureExporter.pdf(content, to: url) }
                else { try content.write(to: url, atomically: true, encoding: .utf8) }
            }
        } catch { alert = error.localizedDescription }
    }
    func ensureReferenceMaterial(_ id: String) {
        guard !materials.contains(where: { $0.id == id }) else { return }
        do {
            guard let row = try database?.rows("SELECT m.*, COALESCE(c.name, '') AS course FROM course_materials m LEFT JOIN courses c ON c.id = m.course_id WHERE m.id = ?", values: [id]).first else {
                alert = "이 근거의 PDF 판본을 찾을 수 없습니다"; return
            }
            materials.append(MaterialItem(id: id, lectureID: row["lecture_id"], courseID: row["course_id"], title: (row["file_name"] ?? "PDF") + " · 보존된 판본", course: row["course"] ?? "", status: row["status"] ?? "", pageCount: row["page_count"].flatMap(Int.init), localPath: row["local_path"], externalURL: row["external_url"], documentKind: nil, teacherName: nil, classificationNeedsReview: false))
        } catch { alert = error.localizedDescription }
    }
    func openBrainSource(_ source: BrainSource) {
        if source.kind == "material" { ensureReferenceMaterial(source.targetID) }
        let kind = SearchHit.Kind(rawValue: source.kind) ?? .lecture
        open(SearchHit(id: source.id, kind: kind, title: source.title, excerpt: source.text,
                                targetID: source.targetID, startMilliseconds: source.milliseconds, pageNumber: source.page))
    }
}
