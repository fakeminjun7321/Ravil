import AppKit
import AVFoundation
import Foundation
import Observation
import UniformTypeIdentifiers

struct RecoverableRecording: Identifiable {
    var id: String { url.path }
    let url: URL
    let startedAt: Date
    let title: String
    let courseID: String?
}

struct UnsavedNoteDraft: Codable {
    let id: String
    let title: String
    let body: String
}

@MainActor @Observable
final class AppModel {
    enum Section: String, CaseIterable, Identifiable {
        case overview = "홈", lectures = "강의", materials = "자료", notes = "위키", exam = "시험", capture = "녹음", codex = "Codex", settings = "설정"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .overview: return "square.grid.2x2"
            case .lectures: return "waveform"
            case .materials: return "doc.text"
            case .notes: return "book.closed"
            case .exam: return "checkmark.rectangle"
            case .capture: return "record.circle"
            case .codex: return "chevron.left.forwardslash.chevron.right"
            case .settings: return "gearshape"
            }
        }
    }

    var section: Section = .overview
    var codex = CodexAppServerClient()
    var google = GoogleDriveAccount()
    var lectures: [LectureItem] = []
    var materials: [MaterialItem] = []
    var courses: [CourseItem] = []
    var notes: [KnowledgeNote] = []
    var selectedLectureID: String?
    var selectedMaterialID: String?
    var requestedMaterialIDFromSearch: String?
    var requestedMaterialPageFromSearch: Int?
    var materialPageJumpID = UUID()
    var selectedNoteID: String?
    var requestedNoteIDFromSearch: String?
    var selectedSubjectGroupID: String?
    var selectedCourseFilterID: String?
    var transcript: [TranscriptItem] = []
    var altSlideSource: AltSlideSource?
    var intelligence: LectureIntelligence?
    var lectureMemoText = ""
    var pendingLectureMemos: [String: String] = [:]
    var playbackPosition = 0.0
    var playbackDuration = 0.0
    var isPlaying = false
    var jumpTargetSegmentID: String?
    var searchQuery = ""
    var searchHits: [SearchHit] = []
    var alert: String?
    var altSyncStatus = ""
    var altFolderSnapshot: AltFolderSnapshot?
    var altWorkspaceSynced = false
    var providerSummary: String?
    var recordingTitle = ""
    var recordingCourseID: String?
    var transcriptionLanguage: String = UserDefaults.standard.string(forKey: "RavilTranscriptionLanguage") ?? "auto"
    var translateTranscription = UserDefaults.standard.bool(forKey: "RavilTranslateTranscription")
    var keywordPrompt: String = UserDefaults.standard.string(forKey: "RavilKeywordPrompt") ?? ""
    var isRecording = false
    var isStartingRecording = false
    var recordingStartedAt: Date?
    var isTranscribing = false
    var recoverableRecordings: [RecoverableRecording] = []
    var unsavedNoteDraft: UnsavedNoteDraft?
    var activeLectureID: String?
    var modelPath: String = AppPaths.resolvedModelPath(saved: UserDefaults.standard.string(forKey: "RavilWhisperModelPath"))
    var executablePath: String = AppPaths.resolvedWhisperCLIPath(saved: UserDefaults.standard.string(forKey: "RavilWhisperExecutablePath"))

    private let recorder = RecorderService()
    private var player: AVPlayer?
    private var playerTimeObserver: Any?
    private var loadedAudioPath: String?
    private var database: LibraryDatabase?
    private var draftRecoveryURL: URL {
        AppPaths.applicationSupport.appendingPathComponent("unsaved-note-draft.json")
    }
    private var lectureMemoRecoveryURL: URL {
        AppPaths.applicationSupport.appendingPathComponent("unsaved-lecture-memos.json")
    }

    init() {
        google.onImported = { [weak self] in self?.refresh() }
        if google.automaticEnabled && google.isConnected { google.startPolling() }
        if let data = try? Data(contentsOf: lectureMemoRecoveryURL),
           let pending = try? JSONDecoder().decode([String: String].self, from: data) {
            pendingLectureMemos = pending
        }
        do {
            database = try LibraryDatabase()
            refresh()
            discoverUnregisteredRecordings()
        } catch { alert = error.localizedDescription }
        restoreUnsavedNoteDraft()
    }

    var databaseLocation: String { database?.location.path ?? AppPaths.database.path }
    var modelReady: Bool { WhisperTranscriber(executable: URL(fileURLWithPath: executablePath), model: URL(fileURLWithPath: modelPath)).isAvailable }
    var selectedLecture: LectureItem? { lectures.first { $0.id == selectedLectureID } }
    var selectedMaterial: MaterialItem? { materials.first { $0.id == selectedMaterialID } }

    func goodnotesHistory(for materialID: String) -> ([GoodnotesVersionItem], GoodnotesChangeSummary?) {
        guard let database else { return ([], nil) }
        do {
            return (try database.goodnotesVersions(for: materialID),
                    try database.goodnotesChangeSummary(for: materialID))
        } catch {
            alert = error.localizedDescription
            return ([], nil)
        }
    }

    func goodnotesOCRStatus(for materialID: String) -> MaterialOCRStatus? {
        do { return try database?.goodnotesOCRStatus(for: materialID) }
        catch { alert = error.localizedDescription; return nil }
    }

    func examScopes() -> [ExamScopeItem] {
        do { return try database?.examScopes() ?? [] }
        catch { alert = error.localizedDescription; return [] }
    }

    func createExamScope(title: String, date: String?,
                         ranges: [(materialID: String, startPage: Int, endPage: Int)]) -> String? {
        do { return try database?.createExamScope(title: title, examDate: date, ranges: ranges) }
        catch { alert = error.localizedDescription; return nil }
    }

    func examMaterials(scopeID: String) -> [ExamMaterialRange] {
        do { return try database?.examMaterials(scopeID: scopeID) ?? [] }
        catch { alert = error.localizedDescription; return [] }
    }

    func rebaseExamScopeMaterial(scopeID: String, oldMaterialID: String,
                                 newMaterialID: String, startPage: Int, endPage: Int) -> Bool {
        do {
            try database?.rebaseExamScopeMaterial(scopeID: scopeID, oldMaterialID: oldMaterialID,
                                                  newMaterialID: newMaterialID,
                                                  startPage: startPage, endPage: endPage)
            return true
        } catch { alert = error.localizedDescription; return false }
    }

    func quizCards(scopeID: String) -> [QuizCardItem] {
        do { return try database?.quizCards(scopeID: scopeID) ?? [] }
        catch { alert = error.localizedDescription; return [] }
    }

    func addQuizCard(scopeID: String, materialID: String, page: Int,
                     question: String, answer: String) -> Bool {
        do {
            _ = try database?.addQuizCard(scopeID: scopeID, materialID: materialID,
                                          page: page, question: question, answer: answer)
            return true
        } catch { alert = error.localizedDescription; return false }
    }

    func nextQuizCard(scopeID: String, excluding seenIDs: Set<String>) -> QuizCardItem? {
        do { return try database?.nextQuizCard(scopeID: scopeID, excluding: seenIDs) }
        catch { alert = error.localizedDescription; return nil }
    }

    func recordQuizReview(cardID: String, grade: QuizGrade) -> Bool {
        do {
            try database?.recordQuizReview(cardID: cardID, grade: grade)
            return true
        } catch { alert = error.localizedDescription; return false }
    }

    func goodnotesOCRPages(for materialID: String) -> [MaterialOCRPage] {
        do { return try database?.goodnotesOCRPages(for: materialID) ?? [] }
        catch { alert = error.localizedDescription; return [] }
    }

    func updateGoodnotesClassification(materialID: String, subject: String,
                                       documentKind: String, teacherName: String?) -> Bool {
        guard let database else { return false }
        do {
            try database.updateGoodnotesClassification(materialID: materialID, subject: subject,
                                                       documentKind: documentKind,
                                                       teacherName: teacherName)
            materials = try database.materials()
            settleMaterialSelection()
            updateSearch()
            return true
        } catch { alert = error.localizedDescription; return false }
    }

    func approveGoodnotesOCR(pageID: String, materialID: String, correctedText: String) -> Bool {
        do {
            try database?.approveGoodnotesOCR(pageID: pageID, materialID: materialID,
                                             correctedText: correctedText)
            if let database {
                _ = try database.reclassifyGoodnotesMaterials()
                materials = try database.materials()
                settleMaterialSelection()
            }
            updateSearch()
            return true
        } catch {
            alert = error.localizedDescription
            return false
        }
    }
    var selectedNote: KnowledgeNote? { notes.first { $0.id == selectedNoteID } }
    var selectedSubjectGroup: SubjectCourseGroup? {
        subjectGroups.first { $0.id == selectedSubjectGroupID }
    }

    var filteredLectures: [LectureItem] {
        if let group = selectedSubjectGroup { return lectures.filter { group.contains($0) } }
        guard let selectedCourseFilterID,
              courses.contains(where: { $0.id == selectedCourseFilterID }) else { return lectures }
        return lectures.filter { $0.courseID == selectedCourseFilterID }
    }

    var filteredMaterials: [MaterialItem] {
        if let group = selectedSubjectGroup { return materials.filter { group.contains($0) } }
        return materials
    }

    var subjectGroups: [SubjectCourseGroup] { SubjectCourseGroup.make(from: courses) }

    func folderItemCount(for group: SubjectCourseGroup) -> Int {
        materials.filter { group.contains($0) }.count + lectures.filter { group.contains($0) }.count
    }

    func folderColorHue(for group: SubjectCourseGroup) -> Int? {
        altFolderSnapshot?.folders.first(where: {
            $0.parentID == nil && $0.name == group.altFolderName
        })?.colorHue ?? group.fallbackColorHue
    }

    func showCourse(_ id: String?) {
        selectedSubjectGroupID = nil
        selectedCourseFilterID = id
        section = .lectures
        selectedLectureID = filteredLectures.first?.id
        if let selectedLectureID { selectLecture(selectedLectureID) }
        else { transcript = []; altSlideSource = nil; intelligence = nil; providerSummary = nil; lectureMemoText = "" }
    }

    func showSubjectGroup(_ id: String) {
        guard let group = subjectGroups.first(where: { $0.id == id }) else { return }
        searchQuery = ""
        selectedSubjectGroupID = id
        selectedCourseFilterID = nil
        showSubjectContent(.materials)
    }

    func showSubjectContent(_ destination: Section) {
        guard destination == .materials || destination == .lectures else { return }
        searchQuery = ""
        section = destination
        if destination == .materials {
            settleMaterialSelection()
        } else {
            if !filteredLectures.contains(where: { $0.id == selectedLectureID }) {
                selectedLectureID = filteredLectures.first?.id
            }
            if let selectedLectureID { selectLecture(selectedLectureID) }
            else { transcript = []; altSlideSource = nil; intelligence = nil; providerSummary = nil; lectureMemoText = "" }
        }
    }

    func showLibrarySection(_ destination: Section) {
        searchQuery = ""
        selectedSubjectGroupID = nil
        selectedCourseFilterID = nil
        if destination == .lectures { showCourse(nil) }
        else {
            section = destination
            if destination == .materials { settleMaterialSelection() }
        }
    }

    private func settleMaterialSelection() {
        if !filteredMaterials.contains(where: { $0.id == selectedMaterialID }) {
            selectedMaterialID = filteredMaterials.first?.id
        }
    }

    func refresh() {
        guard let database else { return }
        altWorkspaceSynced = false
        altFolderSnapshot = nil
        do {
            altFolderSnapshot = try AltFolderSnapshotReader.load()
            if let altFolderSnapshot {
                let result = try database.syncAlt(from: altFolderSnapshot.sourceURL)
                altWorkspaceSynced = result.discovered == altFolderSnapshot.notes.count
                altSyncStatus = "Alt \(altFolderSnapshot.workspaceName) 노트 \(result.discovered)개 확인 · 새로 가져온 노트 \(result.imported)개"
            } else {
                altSyncStatus = "Alt DSHS 폴더 저장소를 찾지 못했습니다"
            }
        } catch {
            altSyncStatus = "Alt 폴더 동기화에 문제가 있습니다: \(error.localizedDescription)"
            alert = error.localizedDescription
        }
        do {
            _ = try database.reclassifyGoodnotesMaterials()
            lectures = try database.lectures()
            materials = try database.materials()
            courses = try database.courses()
            notes = try database.notes()
            if selectedLectureID == nil { selectedLectureID = lectures.first?.id }
            settleMaterialSelection()
            if selectedNoteID == nil { selectedNoteID = notes.first?.id }
            if let selectedLectureID { selectLecture(selectedLectureID, navigate: false) }
            updateSearch()
        } catch { alert = error.localizedDescription }
    }

    func selectLecture(_ id: String, seekTo milliseconds: Int? = nil, navigate: Bool = true) {
        if selectedLectureID != id {
            clearPlayback()
            jumpTargetSegmentID = nil
        }
        if navigate && !filteredLectures.contains(where: { $0.id == id }) {
            selectedSubjectGroupID = nil
            selectedCourseFilterID = nil
        }
        selectedLectureID = id
        if navigate { section = .lectures }
        altSlideSource = nil
        guard let database else { return }
        do {
            transcript = try database.transcript(for: id)
            altSlideSource = try database.altSlideSource(for: id)
            intelligence = try database.intelligence(for: id)
            providerSummary = try database.providerSummary(for: id)
            lectureMemoText = try (pendingLectureMemos[id] ?? database.memo(for: id))
            if let path = selectedLecture?.audioPath { preparePlayback(path: path) }
            else { clearPlayback() }
            if let milliseconds {
                jumpTargetSegmentID = transcript.first(where: { $0.startMilliseconds >= milliseconds })?.id
                play(at: milliseconds)
            } else {
                jumpTargetSegmentID = nil
            }
        } catch { alert = error.localizedDescription }
    }

    func updateSearch() {
        guard let database else { return }
        let text = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { searchHits = []; return }
        do { searchHits = try database.search(text) }
        catch { alert = error.localizedDescription }
    }

    func open(_ hit: SearchHit) {
        selectedSubjectGroupID = nil
        selectedCourseFilterID = nil
        switch hit.kind {
        case .lecture, .transcript: selectLecture(hit.targetID, seekTo: hit.startMilliseconds)
        case .material:
            selectedMaterialID = hit.targetID
            requestedMaterialIDFromSearch = hit.targetID
            requestedMaterialPageFromSearch = hit.pageNumber
            materialPageJumpID = UUID()
            section = .materials
        case .note:
            selectedNoteID = hit.targetID
            requestedNoteIDFromSearch = hit.targetID
            section = .notes
        }
        searchQuery = ""
        searchHits = []
    }

    func play(at milliseconds: Int = 0) {
        guard let path = selectedLecture?.audioPath,
              FileManager.default.fileExists(atPath: path) else {
            alert = "이 강의의 원본 오디오를 찾을 수 없습니다."
            return
        }
        preparePlayback(path: path)
        player?.seek(to: CMTime(seconds: Double(milliseconds) / 1_000, preferredTimescale: 1_000))
        player?.play()
        playbackPosition = Double(milliseconds) / 1_000
        isPlaying = true
    }

    private func preparePlayback(path: String) {
        guard loadedAudioPath != path || player == nil else { return }
        if let playerTimeObserver, let player { player.removeTimeObserver(playerTimeObserver) }
        player?.pause()
        playerTimeObserver = nil
        loadedAudioPath = path
        playbackPosition = 0
        playbackDuration = Double(transcript.last?.endMilliseconds ?? 0) / 1_000
        isPlaying = false
        guard FileManager.default.fileExists(atPath: path) else { player = nil; return }
        player = AVPlayer(url: URL(fileURLWithPath: path))
        playerTimeObserver = player?.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 1_000), queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if time.seconds.isFinite { self.playbackPosition = time.seconds }
                if self.playbackDuration > 0 && self.playbackPosition >= self.playbackDuration - 0.5 {
                    self.isPlaying = false
                }
            }
        }
        Task {
            let asset = AVURLAsset(url: URL(fileURLWithPath: path))
            if let duration = try? await asset.load(.duration), duration.seconds.isFinite,
               loadedAudioPath == path {
                playbackDuration = duration.seconds
            }
        }
    }

    private func clearPlayback() {
        if let playerTimeObserver, let player { player.removeTimeObserver(playerTimeObserver) }
        playerTimeObserver = nil
        player?.pause()
        player = nil
        loadedAudioPath = nil
        playbackPosition = 0
        playbackDuration = 0
        isPlaying = false
    }

    func togglePlayback() {
        guard let path = selectedLecture?.audioPath else { return }
        preparePlayback(path: path)
        if isPlaying {
            player?.pause()
            isPlaying = false
        } else {
            player?.play()
            isPlaying = true
        }
    }

    func seekPlayback(to seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 1_000))
        playbackPosition = seconds
    }

    func stopPlayback() { player?.pause(); isPlaying = false }

    func saveLectureMemo(_ body: String, for lectureID: String) {
        guard let database else { return }
        do {
            try database.saveMemo(body, for: lectureID)
            pendingLectureMemos.removeValue(forKey: lectureID)
            if pendingLectureMemos.isEmpty {
                try? FileManager.default.removeItem(at: lectureMemoRecoveryURL)
            } else {
                try persistPendingLectureMemos()
            }
        } catch {
            pendingLectureMemos[lectureID] = body
            do { try persistPendingLectureMemos() }
            catch { alert = "강의 메모와 복구 파일을 저장하지 못했습니다. 앱을 닫기 전에 내용을 복사해 주세요: \(error.localizedDescription)"; return }
            alert = "강의 메모 DB 저장에 실패해 복구 초안을 남겼습니다: \(error.localizedDescription)"
        }
    }

    private func persistPendingLectureMemos() throws {
        try FileManager.default.createDirectory(at: AppPaths.applicationSupport, withIntermediateDirectories: true)
        try JSONEncoder().encode(pendingLectureMemos).write(to: lectureMemoRecoveryURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: lectureMemoRecoveryURL.path)
    }

    func importPDFViaOpenPanel(courseID: String?, lectureID: String? = nil,
                               subjectName: String? = nil) {
        let panel = NSOpenPanel()
        panel.title = "Ravil에 PDF 추가"
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let database else { return }
        do {
            let material = try database.importLocalPDF(from: url, courseID: courseID,
                                                       lectureID: lectureID, subjectName: subjectName)
            refresh()
            if let lectureID {
                selectLecture(lectureID)
            } else {
                showMaterial(material)
            }
        } catch { alert = "PDF를 가져오지 못했습니다: \(error.localizedDescription)" }
    }

    func importPDFForLecture(_ lecture: LectureItem) {
        importPDFViaOpenPanel(courseID: lecture.courseID, lectureID: lecture.id)
    }

    func importAudioViaOpenPanel(courseID: String?) {
        let panel = NSOpenPanel()
        panel.title = "Ravil에 녹음 파일 추가"
        panel.allowedContentTypes = ["wav", "mp3", "ogg", "flac"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let source = panel.url, let database else { return }
        let accessGranted = source.startAccessingSecurityScopedResource()
        defer { if accessGranted { source.stopAccessingSecurityScopedResource() } }

        let ext = source.pathExtension.lowercased()
        let destination = AppPaths.recordings
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
        do {
            try FileManager.default.createDirectory(at: AppPaths.recordings, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o700)],
                                                  ofItemAtPath: AppPaths.recordings.path)
            try FileManager.default.copyItem(at: source, to: destination)
            do {
                let lectureID = try database.addRecording(
                    title: recordingTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? source.deletingPathExtension().lastPathComponent
                        : recordingTitle,
                    courseID: courseID,
                    audioURL: destination,
                    startedAt: Date(),
                    provider: "ravil_audio_import"
                )
                recordingTitle = ""
                section = .lectures
                refresh()
                selectLecture(lectureID)
                transcribe(lectureID: lectureID, audioURL: destination)
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
        } catch {
            alert = "녹음 파일을 가져오지 못했습니다: \(error.localizedDescription)"
        }
    }

    func openMaterial(_ material: MaterialItem) {
        if let path = material.localPath, FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        } else if let string = material.externalURL, let url = URL(string: string) {
            NSWorkspace.shared.open(url)
        } else {
            alert = "열 수 있는 원본 파일이 없습니다."
        }
    }

    func showMaterial(_ material: MaterialItem) {
        searchQuery = ""
        if !filteredMaterials.contains(where: { $0.id == material.id }) {
            selectedSubjectGroupID = nil
            selectedCourseFilterID = nil
        }
        selectedMaterialID = material.id
        section = .materials
    }

    @discardableResult
    func saveNote(id: String?, title: String, body: String, selectAfterSave: Bool = true,
                  resolvesRecoveredDraft: Bool = false) -> String? {
        let noteID = id ?? UUID().uuidString
        guard let database else {
            if preserveUnsavedNoteDraft(id: noteID, title: title, body: body) {
                alert = "노하우 DB를 열 수 없어 복구 초안을 보관했습니다."
            }
            return nil
        }
        do {
            let note = KnowledgeNote(id: noteID, title: title, body: body,
                                     updatedAt: ISO8601DateFormatter().string(from: Date()))
            try database.saveNote(note)
            if let savedNotes = try? database.notes() {
                notes = savedNotes
            } else if let index = notes.firstIndex(where: { $0.id == note.id }) {
                notes[index] = note
            } else {
                notes.insert(note, at: 0)
            }
            if selectAfterSave { selectedNoteID = note.id }
            if let recovery = unsavedNoteDraft, recovery.id == note.id,
               (resolvesRecoveredDraft || (recovery.title == title && recovery.body == body)) {
                discardUnsavedNoteDraft()
            }
            updateSearch()
            return note.id
        } catch {
            if preserveUnsavedNoteDraft(id: noteID, title: title, body: body) {
                alert = "노하우를 DB에 저장하지 못했습니다. 복구 초안을 보관했습니다: \(error.localizedDescription)"
            }
            return nil
        }
    }

    @discardableResult
    func preserveUnsavedNoteDraft(id: String?, title: String, body: String) -> Bool {
        let draft = UnsavedNoteDraft(id: id ?? unsavedNoteDraft?.id ?? UUID().uuidString,
                                     title: title, body: body)
        unsavedNoteDraft = draft
        do {
            try FileManager.default.createDirectory(at: AppPaths.applicationSupport, withIntermediateDirectories: true)
            try JSONEncoder().encode(draft).write(to: draftRecoveryURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: draftRecoveryURL.path)
            return true
        } catch {
            alert = "노하우 DB와 복구 파일 모두 저장하지 못했습니다. 앱을 닫기 전에 내용을 복사해 주세요: \(error.localizedDescription)"
            return false
        }
    }

    private func restoreUnsavedNoteDraft() {
        guard let data = try? Data(contentsOf: draftRecoveryURL),
              let draft = try? JSONDecoder().decode(UnsavedNoteDraft.self, from: data) else { return }
        if let saved = notes.first(where: { $0.id == draft.id }),
           saved.title == draft.title && saved.body == draft.body {
            try? FileManager.default.removeItem(at: draftRecoveryURL)
            return
        }
        unsavedNoteDraft = draft
    }

    private func discardUnsavedNoteDraft() {
        unsavedNoteDraft = nil
        try? FileManager.default.removeItem(at: draftRecoveryURL)
    }

    func beginRecording() {
        guard !isStartingRecording, !isRecording else { return }
        isStartingRecording = true
        Task {
            defer { isStartingRecording = false }
            do {
                _ = try await recorder.start()
                isRecording = true
                recordingStartedAt = recorder.startedAt
            } catch { alert = error.localizedDescription }
        }
    }

    func finishRecording() {
        do {
            let result = try recorder.stop()
            isRecording = false
            recordingStartedAt = nil
            let pending = RecoverableRecording(url: result.url, startedAt: result.startedAt,
                                               title: recordingTitle, courseID: recordingCourseID)
            recoverableRecordings.append(pending)
            recordingTitle = ""
            registerRecording(pending)
        } catch {
            isRecording = recorder.isRecording
            alert = error.localizedDescription
        }
    }

    func retryRecordingRegistration(_ id: String) {
        guard let pending = recoverableRecordings.first(where: { $0.id == id }) else { return }
        registerRecording(pending)
    }

    private func registerRecording(_ pending: RecoverableRecording) {
        guard let database else {
            alert = "녹음은 이 경로에 보존됐지만 DB를 열 수 없습니다: \(pending.url.path)"
            return
        }
        guard FileManager.default.fileExists(atPath: pending.url.path) else {
            alert = "복구할 녹음 파일을 찾을 수 없습니다: \(pending.url.path)"
            return
        }
        do {
            let lectureID = try database.addRecording(title: pending.title, courseID: pending.courseID,
                                                      audioURL: pending.url, startedAt: pending.startedAt)
            recoverableRecordings.removeAll { $0.id == pending.id }
            activeLectureID = lectureID
            refresh()
            selectLecture(lectureID)
            transcribe(lectureID: lectureID, audioURL: pending.url)
        } catch {
            alert = "녹음은 이 경로에 보존됐습니다. 화면에서 저장을 다시 시도할 수 있습니다: \(pending.url.path)\n\(error.localizedDescription)"
        }
    }

    private func discoverUnregisteredRecordings() {
        guard let database,
              let files = try? FileManager.default.contentsOfDirectory(
                at: AppPaths.recordings,
                includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
              ),
              let rows = try? database.rows("SELECT local_path FROM audio_assets WHERE local_path IS NOT NULL") else { return }
        let registered = Set(rows.compactMap { $0["local_path"] })
        let activePath = recorder.fileURL?.path
        for file in files where file.pathExtension.lowercased() == "wav"
            && !registered.contains(file.path) && file.path != activePath
            && !recoverableRecordings.contains(where: { $0.id == file.path }) {
            let values = try? file.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            recoverableRecordings.append(RecoverableRecording(
                url: file,
                startedAt: values?.creationDate ?? values?.contentModificationDate ?? Date(),
                title: "복구된 녹음",
                courseID: nil
            ))
        }
    }

    func transcribeLecture(_ lectureID: String, language: String) {
        guard let lecture = lectures.first(where: { $0.id == lectureID }),
              lecture.canTranscribe, let path = lecture.audioPath else { return }
        transcribe(lectureID: lecture.id, audioURL: URL(fileURLWithPath: path), language: language)
    }

    private func transcribe(lectureID: String, audioURL: URL, language: String? = nil) {
        guard !isTranscribing else { return }
        isTranscribing = true
        let worker = WhisperTranscriber(executable: URL(fileURLWithPath: executablePath),
                                        model: URL(fileURLWithPath: modelPath))
        let options = TranscriptionOptions(language: language ?? transcriptionLanguage,
                                           translateToEnglish: translateTranscription,
                                           keywordPrompt: keywordPrompt)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try worker.transcribe(audio: audioURL, options: options) }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isTranscribing = false
                switch result {
                case .success(let phrases):
                    do {
                        try self.database?.saveTranscript(phrases, for: lectureID, options: options,
                                                          modelID: worker.model.lastPathComponent)
                        self.refresh()
                    } catch { self.alert = error.localizedDescription }
                case .failure(let error): self.alert = error.localizedDescription
                }
            }
        }
    }

    func saveModelPreferences() {
        UserDefaults.standard.set(modelPath, forKey: "RavilWhisperModelPath")
        UserDefaults.standard.set(executablePath, forKey: "RavilWhisperExecutablePath")
    }

    func saveTranscriptionPreferences() {
        UserDefaults.standard.set(transcriptionLanguage, forKey: "RavilTranscriptionLanguage")
        UserDefaults.standard.set(translateTranscription, forKey: "RavilTranslateTranscription")
        UserDefaults.standard.set(keywordPrompt, forKey: "RavilKeywordPrompt")
    }
}
