import Foundation

/// The OAuth client identifies Ravil; each installation keeps its own user token
/// in Keychain. No developer's Drive folder is embedded as a user default.
enum GoogleDriveConfiguration {
    static var bundledClientID: String {
        (Bundle.main.object(forInfoDictionaryKey: "RavilGoogleClientID") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var bundledClientSecret: String? {
        Bundle.main.object(forInfoDictionaryKey: "RavilGoogleClientSecret") as? String
    }

    static func tokenFields(_ fields: [String: String], bundledID: String,
                            bundledSecret: String?) -> [String: String] {
        var result = fields
        if fields["client_id"] == bundledID, let secret = bundledSecret, !secret.isEmpty {
            result["client_secret"] = secret
        }
        return result
    }

    static func tokenBody(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let body = fields.keys.sorted().map { key in
            let name = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            let value = fields[key]!.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return name + "=" + value
        }.joined(separator: "&")
        return Data(body.utf8)
    }

    static func safeTokenError(_ data: Data) -> String? {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let code = value["error"] as? String
        if code == "invalid_request", (value["error_description"] as? String)?.contains("client_secret") == true {
            return "OAuth 클라이언트 보안 값이 필요합니다."
        }
        switch code {
        case "invalid_client": return "OAuth 클라이언트 설정을 확인해 주세요."
        case "invalid_grant": return "로그인 요청이 만료되었거나 취소됐습니다. 다시 연결해 주세요."
        case "access_denied": return "Google 계정 연결이 거부되었습니다."
        case "invalid_request": return "Google 인증 요청 형식을 확인해 주세요."
        default: return nil
        }
    }

    static func isExpiredRefreshResponse(statusCode: Int, fields: [String: String], data: Data) -> Bool {
        guard fields["grant_type"] == "refresh_token", statusCode == 400,
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return value["error"] as? String == "invalid_grant"
    }

    static func resolvedClientID(override: String?, bundled: String) -> String {
        let custom = (override ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return custom.isEmpty ? bundled.trimmingCharacters(in: .whitespacesAndNewlines) : custom
    }

    static func validClientID(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9_-]+\\.apps\\.googleusercontent\\.com$",
                    options: .regularExpression) != nil
    }

    static func folderID(from input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil { return value }
        guard let url = URL(string: value), url.scheme == "https", url.host == "drive.google.com" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        // Accept both ordinary and account-indexed Drive folder URLs.
        let prefix: [String]
        if parts.count == 3 { prefix = ["drive", "folders"] }
        else if parts.count == 5, Int(parts[2]) != nil { prefix = ["drive", "u", parts[2], "folders"] }
        else { return nil }
        guard Array(parts.dropLast()) == prefix, let id = parts.last,
              id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { return nil }
        return id
    }
}
