import SwiftUI
import AppKit

/// Offscreen layout evidence only; does not launch a visible window or touch input.
enum ClassroomRenderCheck {
    @MainActor static func run(folder: URL) async throws {
        guard AppPaths.isVerificationProfile else { throw DatabaseError.sqlite("화면 렌더 검사는 사본 보관함 프로필에서만 실행합니다") }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = AppModel()
        guard let lecture = model.lectures.first else { throw DatabaseError.sqlite("생성한 검증 강의가 없습니다") }
        model.selectLecture(lecture.id)
        model.classroomMaterialID = model.materials.first?.id
        model.lectureBookmarks = try model.database?.bookmarks(for: lecture.id) ?? []
        try await render(LectureDetailView(model: model, lecture: lecture), name: "classroom", folder: folder)
        model.brain.loadHistory(database: model.database)
        model.brain.sources = try model.database?.brainSources(query: "에너지") ?? []
        model.brain.selected = Set(model.brain.sources.prefix(2).map(\.id))
        model.brain.question = "강의와 학습지의 에너지 설명을 비교해줘"
        try await render(BrainView(model: model), name: "brain", folder: folder)
        try await render(CaptureView(model: model), name: "capture-setup", folder: folder)
        print("Offscreen renders saved; no window shown and no recording started.")
    }
    @MainActor static func render<V: View>(_ view: V, name: String, folder: URL) async throws {
        let host = NSHostingView(rootView: view.frame(width: 1320, height: 820).environment(\.colorScheme, .dark))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 820), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        host.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        defer { window.close() }
        host.frame = NSRect(x: 0, y: 0, width: 1320, height: 820)
        try await Task.sleep(nanoseconds: 750_000_000)
        host.layoutSubtreeIfNeeded()
        guard !window.isVisible, let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw DatabaseError.sqlite("비표시 화면 렌더 실패")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw DatabaseError.sqlite("PNG 생성 실패") }
        try png.write(to: folder.appendingPathComponent(name + ".png"))
    }
}
