import Foundation

// MARK: - Models

/// Response của key server theo chuẩn EME ClearKey license.
/// Ví dụ: {"keys":[{"kty":"oct","kid":"P2XBB8mQTKmN3SJnHVyJww","k":"48b75Mrou_E-1qe-jmaqVQ"}],"type":"temporary"}
/// kid và k đều là base64url.
struct ClearKeyLicenseResponse: Decodable {
    struct JWK: Decodable {
        let kty: String
        let kid: String
        let k: String
    }
    let keys: [JWK]
    let type: String?
}

/// Map kid(hex) -> key(hex), đúng format Shaka `drm.clearKeys` yêu cầu.
/// Shaka docs: "provide a map of key IDs to content keys (both in hex)".
struct ClearKeySet {
    let keys: [String: String]
    var isEmpty: Bool { keys.isEmpty }
}

// MARK: - Errors

enum ClearKeyError: Error, LocalizedError {
    case invalidLicenseURL
    case httpError(Int)
    case emptyKeys
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidLicenseURL: return "license_key URL không hợp lệ"
        case .httpError(let code): return "Key server trả về HTTP \(code)"
        case .emptyKeys: return "Key server không trả về key nào"
        case .invalidResponse: return "Không parse được response của key server"
        }
    }
}

// MARK: - Resolver

/// Lấy ClearKey từ license server của nhà cung cấp.
///
/// Luồng dùng trong MonPlayer:
/// 1. Parse playlist M3U, với kênh DRM sẽ có dòng:
///    #KODIPROP:inputstream.adaptive.license_key=<url>
/// 2. Gọi `fetch(from:)` để lấy key (nhớ dùng UA của IPTV, UA thường ăn 403).
/// 3. Truyền `ClearKeySet.keys` vào ShakaDRMEngine.load(..., clearKeys:).
final class ClearKeyLicenseResolver {

    /// User-Agent mà key server chấp nhận.
    /// Đã verify thực tế (2026-10-13): UA browser/curl -> 403
    /// "DRM Key License is only available on IPTV Applications".
    /// UA của app IPTV (VLC, TiviMate...) -> 200 + JSON keys.
    static let iptvUserAgent = "VLC/3.0.20 LibVLC/3.0.20"

    /// Bóc license_key URL từ dòng #KODIPROP trong playlist.
    static func licenseURL(fromKodipropLine line: String) -> URL? {
        guard let range = line.range(of: "license_key=") else { return nil }
        let urlString = String(line[range.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !urlString.isEmpty else { return nil }
        return URL(string: urlString)
    }

    /// Quét cả playlist M3U, trả về map: streamURL -> licenseURL cho các kênh DRM.
    /// Gọi 1 lần khi load playlist, cache lại để khỏi parse lại mỗi lần chuyển kênh.
    ///
    /// Thứ tự trong playlist (đã verify thực tế):
    ///   #EXTINF:..., ON SPORTS
    ///   #KODIPROP:inputstream.adaptive.license_key=<url>
    ///   https://... (URL stream của chính kênh đó)
    /// Nên license được map vào URL http gần nhất đứng SAU nó.
    static func scanPlaylist(_ m3u: String) -> [String: URL] {
        var result: [String: URL] = [:]
        var pendingLicense: URL?
        let lines = m3u.components(separatedBy: .newlines)
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#KODIPROP"), let url = licenseURL(fromKodipropLine: line) {
                pendingLicense = url
            } else if !line.hasPrefix("#"), line.hasPrefix("http") {
                if let license = pendingLicense {
                    result[line] = license
                    pendingLicense = nil
                }
            }
        }
        return result
    }

    /// Fetch key từ license server, convert sang hex cho Shaka.
    static func fetch(from url: URL) async throws -> ClearKeySet {
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue(iptvUserAgent, forHTTPHeaderField: "User-Agent")

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw ClearKeyError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ClearKeyError.httpError(http.statusCode)
        }

        let decoded: ClearKeyLicenseResponse
        do {
            decoded = try JSONDecoder().decode(ClearKeyLicenseResponse.self, from: data)
        } catch {
            throw ClearKeyError.invalidResponse
        }

        var keys: [String: String] = [:]
        for jwk in decoded.keys {
            guard let kidHex = base64urlToHex(jwk.kid),
                  let keyHex = base64urlToHex(jwk.k) else { continue }
            keys[kidHex] = keyHex
        }
        guard !keys.isEmpty else { throw ClearKeyError.emptyKeys }
        return ClearKeySet(keys: keys)
    }

    /// base64url -> hex lowercase (Shaka cần hex cho cả kid lẫn key).
    static func base64urlToHex(_ s: String) -> String? {
        var b64 = s.replacingOccurrences(of: "-", with: "+")
                   .replacingOccurrences(of: "_", with: "/")
        let pad = b64.count % 4
        if pad > 0 { b64 += String(repeating: "=", count: 4 - pad) }
        guard let data = Data(base64Encoded: b64) else { return nil }
        return data.map { String(format: "%02x", $0) }.joined()
    }
}
