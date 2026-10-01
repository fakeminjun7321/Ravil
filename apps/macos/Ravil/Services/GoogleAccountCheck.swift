import Foundation

enum GoogleAccountCheck {
    @MainActor static func run() async throws {
        let shared = "ravil-shared.apps.googleusercontent.com"
        guard GoogleDriveConfiguration.resolvedClientID(override: nil, bundled: shared) == shared,
              GoogleDriveConfiguration.resolvedClientID(override: "  ", bundled: shared) == shared,
              GoogleDriveConfiguration.resolvedClientID(override: "custom.apps.googleusercontent.com", bundled: shared)
                  == "custom.apps.googleusercontent.com",
              GoogleDriveConfiguration.validClientID(shared),
              !GoogleDriveConfiguration.validClientID("https://evil.example/.apps.googleusercontent.com"),
              GoogleDriveConfiguration.folderID(from: "") == nil,
              GoogleDriveConfiguration.folderID(from: "https://drive.google.com/drive/folders/folder-id?usp=sharing") == "folder-id",
              GoogleDriveConfiguration.folderID(from: "https://drive.google.com/drive/u/1/folders/folder-id") == "folder-id",
              GoogleDriveConfiguration.folderID(from: " folder-id ") == "folder-id",
              GoogleDriveConfiguration.folderID(from: "https://drive.google.com.evil.example/drive/folders/folder-id") == nil,
              GoogleDriveConfiguration.folderID(from: "https://drive.google.com/file/d/file-id/view") == nil else {
            throw GoogleAccountError.invalidClient
        }
        let fields = ["client_id": shared, "code": "a+b/c=d&state"]
        let withSecret = GoogleDriveConfiguration.tokenFields(fields, bundledID: shared, bundledSecret: "fixture-secret")
        let withoutSecret = GoogleDriveConfiguration.tokenFields(fields, bundledID: "other.apps.googleusercontent.com", bundledSecret: "fixture-secret")
        let body = String(decoding: GoogleDriveConfiguration.tokenBody(withSecret), as: UTF8.self)
        let missing = Data(#"{"error":"invalid_request","error_description":"client_secret is missing."}"#.utf8)
        let unsafe = Data(#"{"error":"unknown","error_description":"do not echo credentials"}"#.utf8)
        let expired = Data(#"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#.utf8)
        guard withSecret["client_secret"] == "fixture-secret", withoutSecret["client_secret"] == nil,
              body.contains("code=a%2Bb%2Fc%3Dd%26state"),
              GoogleDriveConfiguration.safeTokenError(missing) == "OAuth 클라이언트 보안 값이 필요합니다.",
              GoogleDriveConfiguration.isExpiredRefreshResponse(statusCode: 400,
                  fields: ["grant_type": "refresh_token"], data: expired),
              !GoogleDriveConfiguration.isExpiredRefreshResponse(statusCode: 400,
                  fields: ["grant_type": "authorization_code"], data: expired),
              !GoogleDriveConfiguration.isExpiredRefreshResponse(statusCode: 401,
                  fields: ["grant_type": "refresh_token"], data: expired),
              !GoogleDriveConfiguration.isExpiredRefreshResponse(statusCode: 400,
                  fields: ["grant_type": "refresh_token"], data: unsafe),
              GoogleDriveConfiguration.safeTokenError(unsafe) == nil else {
            throw GoogleAccountError.invalidClient
        }
        let loopback = GoogleOAuthLoopback(expectedState: "fixture-state")
        let port = try await loopback.start()
        defer { loopback.stop() }
        let wrongURL = URL(string: "http://127.0.0.1:\(port)/oauth2callback?state=wrong&code=bad")!
        let (_, wrongResponse) = try await URLSession.shared.data(from: wrongURL)
        guard (wrongResponse as? HTTPURLResponse)?.statusCode == 400 else {
            throw GoogleAccountError.callbackInvalid
        }
        let goodURL = URL(string: "http://127.0.0.1:\(port)/oauth2callback?state=fixture-state&code=fixture-code")!
        let (_, goodResponse) = try await URLSession.shared.data(from: goodURL)
        guard (goodResponse as? HTTPURLResponse)?.statusCode == 200,
              try await loopback.waitForCode() == "fixture-code" else {
            throw GoogleAccountError.callbackInvalid
        }
        print("Ravil Google OAuth loopback: shared app configuration, user folder validation, local-only listener, wrong-state rejection, and code callback passed")
    }
}
