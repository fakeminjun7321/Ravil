import AppKit
import SwiftUI
import Foundation

enum WorkspaceCheck {
    @MainActor static func run(input: URL, image: URL? = nil) throws {
        let body = try String(contentsOf: input, encoding: .utf8)
        let reference = ISO8601DateFormatter().date(from: "2026-10-04T00:00:00Z")!
        let parsed = WorkspacePlanParser.parse(body, referenceDate: reference)
        guard parsed.tasks.count == 22, parsed.tasks.reduce(0, { $0 + $1.repetitions }) == 25,
              parsed.tasks.filter({ $0.day == "2026-10-14" }).count == 12,
              parsed.tasks.filter({ $0.day == "2026-10-15" }).count == 10 else {
            throw DatabaseError.sqlite("원문 날짜·단원·반복 횟수를 보존하지 못했습니다.")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RavilWorkspaceCheck-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PersonalWorkspace(root: folder, useKeychain: false)
        let subject = try store.put("subject", ["title": .string("물리")])
        let project = try store.put("project", ["title": .string("중간고사"), "phase": .string("active"), "kind": .string("exam"), "examDate": .string("2026-10-15")])
        let record = try store.saveRecord(id: nil, title: "광학 공부 계획", body: body, subjectID: subject.id, projectID: project.id)
        guard try store.organize(record) == 22 else { throw DatabaseError.sqlite("할 일 생성에 실패했습니다.") }
        let repeated = store.items("task").first { $0.payload.int("repetitions") == 3 }!
        try store.complete(repeated)
        var custom = store.get(repeated.id)!.payload; custom["minutes"] = .number(45)
        _ = try store.put("task", custom, id: repeated.id)
        _ = try store.organize(store.get(record.id)!)
        guard store.get(repeated.id)?.payload.int("completed") == 1,
              store.get(repeated.id)?.payload.int("minutes") == 45 else { throw DatabaseError.sqlite("다시 정리하면서 진행이나 시간을 잃었습니다.") }
        let reopened = PersonalWorkspace(root: folder, useKeychain: false)
        guard reopened.get(record.id)?.payload.text("body") == body,
              reopened.search("전에 적은 물리 파동광학").contains(where: { $0.id == record.id }) else { throw DatabaseError.sqlite("저장·재열기·검색 검사에 실패했습니다.") }
        for minutes in [10, 20, 50] { try store.observe("study", recordID: record.id, minutes: minutes, action: "학습지 정독") }
        let next = try store.saveRecord(id: nil, title: "다음 계획", body: "10.16\n파동광학\n(1) 학습지 정독", subjectID: subject.id, projectID: "")
        _ = try store.organize(next)
        guard store.items("task").first(where: { $0.payload.text("recordID") == next.id })?.payload.int("minutes") == 20 else {
            throw DatabaseError.sqlite("실제 활동을 다음 예상 시간에 반영하지 못했습니다.")
        }
        var historic = next.payload; historic["createdAt"] = .string("2025-10-04T00:00:00.123Z")
        let old = try store.put("record", historic)
        _ = try store.organize(old)
        guard store.items("task").first(where: { $0.payload.text("recordID") == old.id })?.payload.text("day") == "2025-10-16" else {
            throw DatabaseError.sqlite("지난 기록의 작성 연도를 보존하지 못했습니다.")
        }
        if let image {
            NSApplication.shared.setActivationPolicy(.prohibited)
            NSApplication.shared.appearance = NSAppearance(named: .aqua)
            store.selectedRecordID = record.id
            let view = NSHostingView(rootView: WorkspaceView(workspace: store, google: GoogleDriveAccount(verificationOnly: true))
                .environment(\.colorScheme, .light).background(Color(nsColor: .windowBackgroundColor)))
            view.appearance = NSAppearance(named: .aqua)
            view.frame = NSRect(x: 0, y: 0, width: 1250, height: 850)
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw DatabaseError.sqlite("화면을 렌더링하지 못했습니다.") }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { throw DatabaseError.sqlite("화면 파일을 저장하지 못했습니다.") }
            try FileManager.default.createDirectory(at: image.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: image)
        }
        print("Workspace check passed: 22 tasks / 25 repetitions; original, completion, duration, persistence and retrieval preserved.")
    }
    private struct Fixture: Decodable { let base: String; let email: String; let password: String }
    @MainActor static func cloud(fixture: URL) async throws {
        let f = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: fixture))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RavilWorkspaceCloudCheck-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = PersonalWorkspace(baseURL: f.base, root: folder.appendingPathComponent("a"), useKeychain: false)
        let b = PersonalWorkspace(baseURL: f.base, root: folder.appendingPathComponent("b"), useKeychain: false)
        try await a.signIn(email: f.email, password: f.password)
        try await b.signIn(email: f.email, password: f.password)
        let record = try a.saveRecord(id: nil, title: "Mac 동기화 검증", body: "Mac에서 처음 남긴 기록", subjectID: "", projectID: "")
        await a.sync(); guard a.error == nil else { throw DatabaseError.sqlite(a.error!) }
        await b.sync(); guard b.get(record.id)?.payload.text("body") == "Mac에서 처음 남긴 기록" else { throw DatabaseError.sqlite("같은 계정의 두 Mac 클라이언트가 연결되지 않았습니다.") }
        let baseline = b.get(record.id)!.revision
        _ = try b.saveRecord(id: record.id, title: record.title, body: "오프라인 클라이언트 수정", subjectID: "", projectID: "", expectedRevision: baseline)
        _ = try a.saveRecord(id: record.id, title: record.title, body: "먼저 저장한 수정", subjectID: "", projectID: "")
        await a.sync(); await b.sync()
        guard b.get(record.id)?.remoteJSON != nil,
              b.get(record.id)?.payload.text("body") == "오프라인 클라이언트 수정" else { throw DatabaseError.sqlite("동시 수정의 원문을 잃었습니다.") }
        try await b.resolveConflict(record.id, keepCopy: true)
        guard b.get(record.id)?.payload.text("body") == "먼저 저장한 수정",
              b.items("record").contains(where: { $0.id != record.id && $0.payload.text("body") == "오프라인 클라이언트 수정" }) else { throw DatabaseError.sqlite("두 수정본을 모두 보존하지 못했습니다.") }
        let other = PersonalWorkspace(baseURL: f.base, root: folder.appendingPathComponent("other"), useKeychain: false)
        try await other.signIn(email: f.email.replacingOccurrences(of: "workspace-qa-", with: "workspace-qa-b-"), password: f.password)
        guard !other.items("record").contains(where: { $0.id == record.id }) else { throw DatabaseError.sqlite("다른 계정의 기록이 표시되었습니다.") }
        print("Workspace cloud client check passed: authenticated native clients, account isolation, persistence, conflict and both revisions preserved.")
    }
}
