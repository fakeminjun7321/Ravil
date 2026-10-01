import AppKit
import Foundation

enum GoogleDriveSourceCheck {
    static func run() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("RavilDriveHTTPCheck-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = folder.appendingPathComponent("source.pdf")
        var box = CGRect(x: 0, y: 0, width: 120, height: 160)
        guard let consumer = CGDataConsumer(url: fixture as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw GoodnotesSyncError.invalidResponse
        }
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        MockDriveURLProtocol.pdf = try Data(contentsOf: fixture)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockDriveURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let source = GoogleDrivePDFSource(accessToken: "fixture-token", session: session)
        try await source.validateRoot(id: "midterm-root")
        let files = try await source.children(of: "midterm-root")
        guard files.count == 2, files.map(\.id) == ["f1", "f2"],
              files[0].revision == "r1", files[1].revision == "2" else {
            throw GoodnotesSyncError.invalidResponse
        }
        let downloaded = folder.appendingPathComponent("download.pdf")
        try await source.downloadPDF(id: "f1", to: downloaded)
        guard try Data(contentsOf: downloaded) == MockDriveURLProtocol.pdf else {
            throw GoodnotesSyncError.invalidResponse
        }
        print("Ravil Drive HTTP check: folder validation, Bearer header, pagination, revisions, and PDF download passed")
    }
}

private final class MockDriveURLProtocol: URLProtocol {
    static var pdf = Data()

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "www.googleapis.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token" else {
            client?.urlProtocol(self, didFailWithError: GoodnotesSyncError.invalidResponse)
            return
        }
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = Dictionary(uniqueKeysWithValues: (parts?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let body: Data
        if url.path == "/drive/v3/files/midterm-root" {
            body = Data("""
                {"id":"midterm-root","mimeType":"application/vnd.google-apps.folder","trashed":false,"capabilities":{"canListChildren":true}}
                """.utf8)
        } else if url.path == "/drive/v3/files", query["pageToken"] == nil {
            body = Data("""
                {"files":[{"id":"f1","name":"one.pdf","mimeType":"application/pdf","headRevisionId":"r1","size":"512"}],"nextPageToken":"next"}
                """.utf8)
        } else if url.path == "/drive/v3/files", query["pageToken"] == "next" {
            body = Data("""
                {"files":[{"id":"f2","name":"two.pdf","mimeType":"application/pdf","version":"2","size":"512"}]}
                """.utf8)
        } else if url.path == "/drive/v3/files/f1", query["alt"] == "media" {
            body = Self.pdf
        } else {
            client?.urlProtocol(self, didFailWithError: GoodnotesSyncError.invalidResponse)
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": url.path.hasSuffix("f1")
                                                      ? "application/pdf" : "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { }
}
