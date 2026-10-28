import Foundation
// Focused headless checks. The command-line route never creates an NSApplication.
private struct ConnectionCheckSkipped: Error { let message: String; init(_ message: String) { self.message = message } }
private func expect(_ value: @autoclosure () -> Bool, _ message: String = "Assertion failed", file: StaticString = #file, line: UInt = #line) { precondition(value(), message, file:file, line:line) }
private func expectFalse(_ value: @autoclosure () -> Bool, _ message: String = "Expected false", file: StaticString = #file, line: UInt = #line) { precondition(!value(), message, file:file, line:line) }
private func expectEqual<T:Equatable>(_ left: @autoclosure () throws -> T, _ right: @autoclosure () throws -> T, _ message: String = "Values differ", file: StaticString = #file, line: UInt = #line) { do {let a=try left(), b=try right(); precondition(a==b, message, file:file, line:line)} catch {preconditionFailure(error.localizedDescription, file:file, line:line)} }
private func expectNil<T>(_ value: @autoclosure () -> T?, _ message: String = "Expected nil", file: StaticString = #file, line: UInt = #line) { precondition(value()==nil, message, file:file, line:line) }
private func expectNotNil<T>(_ value: @autoclosure () -> T?, _ message: String = "Expected a value", file: StaticString = #file, line: UInt = #line) { precondition(value() != nil, message, file:file, line:line) }
private func expectThrows<T>(_ operation: @autoclosure () throws -> T, _ message: String = "Expected rejection", file: StaticString = #file, line: UInt = #line) { do { _ = try operation() } catch { return }; preconditionFailure(message, file:file, line:line) }
private func require<T>(_ value: T?) throws -> T { guard let value else { throw DatabaseError.sqlite("Missing verification fixture") }; return value }


@MainActor final class ConnectionClientChecks {
    let fixtureDirectory: URL
    init(fixtureDirectory: URL) { self.fixtureDirectory = fixtureDirectory }
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "RavilTests-" + UUID().uuidString)! }
    private func eventually(_ condition: @MainActor () -> Bool, seconds: Double = 8) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !condition(), Date() < end { try await Task.sleep(for: .milliseconds(30)) }
        expect(condition(), "Expected asynchronous connection state before timeout")
    }
    private func server(_ mode: String) async throws -> (Process, URL, String) {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("RavilModelTest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let process=Process(); process.executableURL=URL(fileURLWithPath: "/usr/bin/env")
        let fixture=try require(fixtureDirectory.appendingPathComponent("local-model-server.py"))
        process.arguments=["python3",fixture.path,mode,directory.appendingPathComponent("port").path,directory.appendingPathComponent("redirect").path]
        process.standardOutput=FileHandle.nullDevice; process.standardError=FileHandle.nullDevice
        try process.run()
        try await eventually({FileManager.default.fileExists(atPath: directory.appendingPathComponent("port").path)})
        let port=try String(contentsOf: directory.appendingPathComponent("port")).trimmingCharacters(in: .whitespacesAndNewlines)
        return (process,directory,"http://127.0.0.1:\(port)/v1")
    }
    func testLocalEndpointBoundary() throws {
        for endpoint in ["http://localhost:1234", "http://127.0.0.1:11434/v1/", "http://[::1]:1234/v1"] {
            let path = try LocalModelClient.baseURL(endpoint).path
            expectEqual(path, "/v1")
        }
        for endpoint in ["https://example.com/v1", "http://127.0.0.1.evil.invalid/v1", "file:///etc/passwd", "http://user:pass@localhost/v1", "http://localhost/v1?token=x", "http://localhost/v1#x", "http://localhost/admin", "http://localhost:0/v1"] {
            expectThrows(try LocalModelClient.baseURL(endpoint), endpoint)
        }
    }
    func testLocalHTTPDiscoveryAnswerFailureCancellationAndSettingsIsolation() async throws {
        let (process,folder,address)=try await server("normal")
        defer { if process.isRunning {process.terminate()}; try? FileManager.default.removeItem(at: folder) }
        let preferences=defaults(), client=LocalModelClient(defaults: preferences)
        client.endpoint=address; client.apiKey="fixture-only-key"; client.connect()
        try await eventually({!client.connecting})
        expect(client.ready); expectEqual(client.availableModels,["fixture-model"])
        expect(client.send("테스트 메모")); try await eventually({!client.sending})
        expectEqual(client.lastResponse,"로컬 기록 정리")
        expectNil(preferences.string(forKey:"apiKey")); expectFalse(preferences.dictionaryRepresentation().values.contains { ($0 as? String)=="fixture-only-key" })
        expect(client.send("FAIL")); try await eventually({!client.sending})
        expectNil(client.lastResponse); expectNotNil(client.errorMessage)
        expect(client.send("SLOW")); client.cancel()
        try await Task.sleep(for: .milliseconds(700))
        expectFalse(client.sending); expectNil(client.lastResponse)
        expectEqual(client.messages.last?.text,"응답을 중단했습니다.")
        client.endpoint="http://127.0.0.1:1/v1"
        expectFalse(client.send("변경 후 전송")); expectNotNil(client.errorMessage)
        client.disconnect(); expect(client.messages.isEmpty)
        expectFalse(client.send("연결 전 초안"))
    }
    func testLocalRedirectDoesNotForwardRequest() async throws {
        let (process,folder,address)=try await server("redirect")
        defer { if process.isRunning {process.terminate()}; try? FileManager.default.removeItem(at: folder) }
        let client=LocalModelClient(defaults:defaults());client.endpoint=address;client.apiKey="fixture-key";client.connect()
        try await eventually({!client.connecting})
        expectFalse(client.connected);expectNotNil(client.errorMessage)
        expectFalse(FileManager.default.fileExists(atPath:folder.appendingPathComponent("redirect").path))
        client.disconnect()
    }
    func testEmptyModelCatalogDoesNotEnableSending() async throws {
        let (process,folder,address)=try await server("empty")
        defer { if process.isRunning {process.terminate()}; try? FileManager.default.removeItem(at: folder) }
        let client=LocalModelClient(defaults:defaults());client.endpoint=address;client.connect()
        try await eventually({!client.connecting})
        expectFalse(client.ready);expectFalse(client.send("보존할 초안"));client.disconnect()
    }
    func testCodexStdioLifecycleWithFixtureServer() async throws {
        let fixture=try require(fixtureDirectory.appendingPathComponent("codex-server.py"))
        let executable=FileManager.default.temporaryDirectory.appendingPathComponent("ravil-codex-test-"+UUID().uuidString)
        try FileManager.default.copyItem(at:fixture,to:executable)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:executable.path)
        defer {try? FileManager.default.removeItem(at:executable)}
        let client=CodexAppServerClient(defaults:defaults());client.executablePath=executable.path;client.connect()
        defer {client.disconnect()}
        try await eventually({client.ready})
        expectEqual(client.selectedModel,"fixture-model")
        expect(client.send("기록 정리"));try await eventually({!client.sending})
        expectEqual(client.lastResponse,"기록에서 찾은 생각")
        expect(client.send("FAIL"));try await eventually({!client.sending})
        expectNil(client.lastResponse);expectEqual(client.errorMessage,"fixture failure")
        expect(client.send("CANCEL"));try await Task.sleep(for:.milliseconds(100));client.cancel()
        try await eventually({!client.sending});expectNil(client.lastResponse)
        expect(client.send("CANCEL_RACE"));try await Task.sleep(for:.milliseconds(100));client.cancel()
        try await eventually({!client.sending});expectNil(client.lastResponse)
        client.disconnect();expect(client.messages.isEmpty);expectFalse(client.ready)
    }
    func testLiveCodexHandshakeOnly() async throws {
        guard ProcessInfo.processInfo.environment["RAVIL_VERIFY_LIVE_CONNECTIONS"]=="1" else {throw ConnectionCheckSkipped("Real-account metadata check is opt-in; never invokes a model turn")}
        let client=CodexAppServerClient(defaults:defaults());defer{client.disconnect()};client.connect()
        try await eventually({!client.connecting},seconds:35)
        expect(client.connected,client.errorMessage ?? client.status)
        expect(client.accountConnected);expectFalse(client.availableModels.isEmpty)
        expect(client.messages.isEmpty)
        print("LIVE_CODEX_HANDSHAKE models=\(client.availableModels.count); inference not invoked")
    }
    func testLiveOllamaSelectedExistingModel() async throws {
        guard ProcessInfo.processInfo.environment["RAVIL_VERIFY_LIVE_CONNECTIONS"]=="1" else {throw ConnectionCheckSkipped("Existing local-model inference is opt-in")}
        let client=LocalModelClient(defaults:defaults());defer{client.disconnect()};client.connect()
        try await eventually({!client.connecting},seconds:15);expect(client.ready,client.errorMessage ?? client.status)
        guard client.availableModels.contains("qwen3:4b-instruct") else {throw ConnectionCheckSkipped("Small existing local model not available; no download performed")}
        client.selectedModel="qwen3:4b-instruct"
        expect(client.send("한국어로 한 문장만 답하세요. 오늘 책상 정리를 했다는 메모의 짧은 제목을 제안하세요."))
        try await eventually({!client.sending},seconds:180)
        expectNotNil(client.lastResponse,client.errorMessage ?? client.status)
        print("LIVE_OLLAMA_RESPONSE model=qwen3:4b-instruct; nonempty=\(client.lastResponse?.isEmpty==false)")
    }
}

@MainActor final class WorkspaceAnalysisChecks {
    func testCanonicalInputDigestMatchesWebUTF8AndSlash() throws {
        let payload:[String:WorkspaceValue] = ["title":.string("기록 / 사진집"),"body":.string("첫 생각\n본문"),"format":.string("markdown"),"subjectIDs":.list(["s2","s1"]),"projectIDs":.list(["p1"])]
        let digest = try WorkspaceAnalysisSupport.inputDigest(payload)
        expectEqual(digest,"ec6cb2a5803534cb29a5ca49d9576a87e55f5657bb55b7f3d844721289d64160")
    }
    func testAnalysisPreservesOriginalAndRejectsOwnerOrInputMismatch() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("RavilAnalysisTest-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let store=PersonalWorkspace(baseURL:"http://127.0.0.1:1",root:root,useKeychain:false)
        var record=try store.saveRecord(id:nil,title:"사진집 아이디어",body:"  문장을 / 그대로\n남긴다.  ",subjectID:"",projectID:"")
        var payload=record.payload;payload["tags"] = .list(["내 태그"]);record=try store.put("record",payload,id:record.id)
        let output:WorkspaceValue = .object(["summary":.string("사진집을 위한 생각"),"inputDigest":.string(try WorkspaceAnalysisSupport.inputDigest(record.payload)),"ownerID":.string(store.owner)])
        let saved=try store.saveAnalysis(record,result:output,expectedOwner:store.owner)
        expectEqual(saved.payload.text("body"),record.payload.text("body"));expectEqual(saved.payload.list("tags"),["내 태그"])
        expectEqual(WorkspaceAnalysisSupport.current(saved.payload)?.text("summary"),"사진집을 위한 생각")
        var tagged=saved.payload; tagged["tags"] = .list(["내 태그","AI 제안 태그"])
        tagged["format"] = .string("plain")
        let classified=try store.put("record",tagged,id:record.id)
        expectNotNil(WorkspaceAnalysisSupport.current(classified.payload))
        expectEqual(classified.payload.list("tags"),["내 태그","AI 제안 태그"])
        expectThrows(try store.saveAnalysis(record,result:output,expectedOwner:"another-owner"))
        expectThrows(try store.saveAnalysis(record,result:.object(["summary":.string("구버전 응답")]),expectedOwner:store.owner))
        var wrong=output.object;wrong["inputDigest"] = .string("different");expectThrows(try store.saveAnalysis(record,result:.object(wrong),expectedOwner:store.owner))
        var changed=classified.payload;changed["body"] = .string("새로 남긴 생각")
        let updated=try store.put("record",changed,id:record.id)
        expectNil(WorkspaceAnalysisSupport.current(updated.payload));expectEqual(updated.payload["aiAnalysis"]?.object["stale"],.bool(true))
        expectThrows(try store.saveAnalysis(record,result:output,expectedOwner:store.owner))
        let reopened=PersonalWorkspace(baseURL:"http://127.0.0.1:1",root:root,useKeychain:false)
        expectEqual(reopened.get(record.id)?.payload.text("body"),"새로 남긴 생각")
    }
    func testMultipleLinksAndEvenMedianArePreserved() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("RavilLinksTest-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let store=PersonalWorkspace(baseURL:"http://127.0.0.1:1",root:root,useKeychain:false)
        let record=try store.saveRecord(id:nil,title:"자료 비교",body:"- [ ] 용지 비교하기",subjectID:"s1",projectID:"p1")
        var payload=record.payload;payload["subjectIDs"] = .list(["s1","s2"]);payload["projectIDs"] = .list(["p1","p2"])
        _ = try store.put("record",payload,id:record.id)
        let saved=try store.saveRecord(id:record.id,title:record.title,body:record.payload.text("body"),subjectID:"s1",projectID:"p1")
        expectEqual(saved.payload.list("subjectIDs"),["s1","s2"]);expectEqual(saved.payload.list("projectIDs"),["p1","p2"])
        for minutes in [10,20,30,40] {try store.observe("study",recordID:saved.id,minutes:minutes,action:"용지 비교하기")}
        _ = try store.organize(saved)
        let task=try require(store.items("task").first{$0.payload.text("recordID")==saved.id})
        expectEqual(task.payload.int("minutes"),25)
        expectEqual(task.payload.text("day"),"")
        try store.complete(task)
        _ = try store.organize(try require(store.get(saved.id)))
        expectEqual(store.get(task.id)?.payload.int("completed"),1)
    }
    func testProjectAndArchivedNamesRemainSearchableWithoutTopic() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("RavilSearchTest-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let store=PersonalWorkspace(baseURL:"http://127.0.0.1:1",root:root,useKeychain:false)
        let project=try store.put("project",["title":.string("사진집"),"kind":.string("project"),"phase":.string("active")])
        let record=try store.saveRecord(id:nil,title:"인쇄 아이디어",body:"무광 용지",subjectID:"",projectID:project.id)
        expect(store.search("사진집").contains{$0.id==record.id})
        var payload=record.payload;payload["projectIDs"] = .list([]);payload["projectHistory"] = .list(["사진집"])
        _ = try store.put("record",payload,id:record.id)
        expect(store.search("사진집").contains{$0.id==record.id})
    }
}

@MainActor enum ConnectionCheck {
    static func run(fixtures: URL) async throws {
        let clients=ConnectionClientChecks(fixtureDirectory:fixtures)
        try clients.testLocalEndpointBoundary(); print("PASS local endpoint boundary")
        try await clients.testLocalHTTPDiscoveryAnswerFailureCancellationAndSettingsIsolation(); print("PASS local HTTP discovery, answer, failure, cancellation, settings")
        try await clients.testLocalRedirectDoesNotForwardRequest(); print("PASS local redirect refusal")
        try await clients.testEmptyModelCatalogDoesNotEnableSending(); print("PASS empty model catalog")
        try await clients.testCodexStdioLifecycleWithFixtureServer(); print("PASS Codex fixture stdio, answer, failure, cancellation")
        let workspace=WorkspaceAnalysisChecks()
        try workspace.testCanonicalInputDigestMatchesWebUTF8AndSlash(); print("PASS native/web UTF8 input digest")
        try workspace.testAnalysisPreservesOriginalAndRejectsOwnerOrInputMismatch(); print("PASS original preservation, stale results, owner and input rejection")
        try workspace.testProjectAndArchivedNamesRemainSearchableWithoutTopic(); print("PASS topic-free project and archive search")
        try workspace.testMultipleLinksAndEvenMedianArePreserved(); print("PASS multiple links, even median, undated tasks and progress preservation")
        do { try await clients.testLiveCodexHandshakeOnly() } catch let skip as ConnectionCheckSkipped { print("SKIP "+skip.message) }
        do { try await clients.testLiveOllamaSelectedExistingModel() } catch let skip as ConnectionCheckSkipped { print("SKIP "+skip.message) }
    }
}
