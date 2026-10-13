import Foundation

/// Một kênh trong playlist M3U.
struct Channel: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let logo: String?
    let url: String
    /// Header gắn vào mọi request (từ #EXTVLCOPT), ví dụ ["User-Agent": "Dalvik/2.1.0"]
    let headers: [String: String]
    /// URL key server (từ #KODIPROP...license_key=), nil nếu kênh không DRM
    let licenseURL: URL?
    var hasDRM: Bool { licenseURL != nil }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: Channel, rhs: Channel) -> Bool { lhs.id == rhs.id }
}

enum M3UParser {
    /// Parse M3U text -> danh sách kênh.
    /// Hỗ trợ: #EXTINF (tên, tvg-logo), #EXTVLCOPT:http-xxx (header),
    /// #KODIPROP...license_key= (DRM).
    static func parse(_ text: String) -> [Channel] {
        var channels: [Channel] = []
        var pendingName = "Không tên"
        var pendingLogo: String?
        var pendingHeaders: [String: String] = [:]
        var pendingLicense: URL?

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("#EXTINF") {
                // Reset cho kênh mới
                pendingName = "Không tên"
                pendingLogo = nil
                pendingHeaders = [:]
                pendingLicense = nil
                // Tên kênh nằm sau dấu phẩy cuối
                if let comma = line.lastIndex(of: ",") {
                    let name = line[line.index(after: comma)...].trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { pendingName = name }
                }
                // Logo: tvg-logo="..."
                if let r = line.range(of: #"tvg-logo="([^"]+)""#, options: .regularExpression) {
                    let m = String(line[r])
                    pendingLogo = m.replacingOccurrences(of: #"tvg-logo=""#, with: "")
                                     .replacingOccurrences(of: "\"", with: "")
                }
            } else if line.hasPrefix("#EXTVLCOPT:") {
                // #EXTVLCOPT:http-user-agent=Dalvik/2.1.0 -> ["User-Agent": ...]
                let kv = line.dropFirst("#EXTVLCOPT:".count)
                if let eq = kv.firstIndex(of: "=") {
                    var key = String(kv[..<eq]).trimmingCharacters(in: .whitespaces)
                    let value = String(kv[kv.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                    if key.lowercased().hasPrefix("http-") {
                        key = String(key.dropFirst("http-".count))
                    }
                    // Chuẩn hoá tên header phổ biến
                    let canonical: String
                    switch key.lowercased() {
                    case "user-agent": canonical = "User-Agent"
                    case "referer", "referrer": canonical = "Referer"
                    case "origin": canonical = "Origin"
                    default: canonical = key
                    }
                    pendingHeaders[canonical] = value
                }
            } else if line.hasPrefix("#KODIPROP"),
                      let url = ClearKeyLicenseResolver.licenseURL(fromKodipropLine: line) {
                pendingLicense = url
            } else if !line.hasPrefix("#"), line.hasPrefix("http") {
                channels.append(Channel(name: pendingName,
                                        logo: pendingLogo,
                                        url: line,
                                        headers: pendingHeaders,
                                        licenseURL: pendingLicense))
                // Reset để kênh sau không ăn ké
                pendingName = "Không tên"
                pendingLogo = nil
                pendingHeaders = [:]
                pendingLicense = nil
            }
        }
        return channels
    }

    /// Tải playlist từ URL.
    static func load(from urlString: String) async throws -> [Channel] {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.setValue("VLC/3.0.20 LibVLC/3.0.20", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let text = String(data: data, encoding: .utf8) else {
            throw URLError(.cannotDecodeContentData)
        }
        return parse(text)
    }
}
