import SwiftUI
import WebKit

// MARK: - ShakaDRMEngine
//
// Engine phát DRM trên iOS: WKWebView + Shaka Player (file JS bundle local).
//
// Phủ DRM:
//   ✅ ClearKey (DASH/HLS)  -> qua EME `org.w3.clearkey`
//   ✅ FairPlay             -> qua EME `com.apple.fps` (cần FPS cert + license server,
//                              xem phần cấu hình trong drm-player.js)
//   ❌ Widevine             -> KHÔNG có CDM trên iOS, không app nào làm được
//   ❌ PlayReady            -> không có trên iOS
//
// Lưu ý ổn định lâu dài:
//   - shaka-player.ui.js bundle LOCAL trong app (đừng dùng CDN): pin version,
//     không phụ thuộc mạng lúc mở player.

/// Sự kiện JS gửi về native.
enum ShakaPlayerEvent {
    case ready
    case log(String)
    case error(code: Int, message: String)
    case state(String)   // "playing" | "paused" | "buffering" | "ended"
}

final class ShakaDRMEngine: NSObject {

    let webView: WKWebView
    var onEvent: ((ShakaPlayerEvent) -> Void)?

    private var htmlLoaded = false
    private var pendingLoad: (() -> Void)?

    override init() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let userController = WKUserContentController()
        config.userContentController = userController

        self.webView = WKWebView(frame: .zero, configuration: config)
        super.init()

        userController.add(self, name: "playerBridge")
        webView.navigationDelegate = self
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
    }

    /// Nạp drm-player.html từ bundle. Gọi 1 lần lúc khởi tạo màn hình player.
    /// Các file drm-player.html / drm-player.js / shaka-player.ui.js nằm phẳng
    /// ở bundle root (Copy Bundle Resources), html load js bằng đường dẫn tương đối.
    func loadPlayerPage() {
        guard let htmlURL = Bundle.main.url(forResource: "drm-player", withExtension: "html") else {
            onEvent?(.error(code: -1, message: "Không tìm thấy drm-player.html trong bundle"))
            return
        }
        webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
    }

    /// Phát 1 kênh.
    /// - clearKeys: map kid(hex) -> key(hex). Rỗng/nil = kênh không DRM.
    /// - headers: gắn vào mọi request (manifest, segment, license).
    func load(streamURL: URL, clearKeys: [String: String]?, headers: [String: String] = [:]) {
        let work = { [weak self] in
            guard let self else { return }
            do {
                var payload: [String: Any] = [
                    "url": streamURL.absoluteString,
                    "headers": headers,
                ]
                if let keys = clearKeys, !keys.isEmpty {
                    payload["drmKeys"] = keys
                }
                let json = try JSONSerialization.data(withJSONObject: payload)
                guard var jsonString = String(data: json, encoding: .utf8) else { return }
                jsonString = jsonString
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "'", with: "\\'")
                self.webView.evaluateJavaScript("window.loadChannel('\(jsonString)')") { _, err in
                    if let err {
                        self.onEvent?(.error(code: -2, message: "loadChannel failed: \(err.localizedDescription)"))
                    }
                }
            } catch {
                self.onEvent?(.error(code: -3, message: "Encode payload failed: \(error.localizedDescription)"))
            }
        }

        if htmlLoaded {
            work()
        } else {
            pendingLoad = work
        }
    }

    func play()  { webView.evaluateJavaScript("window.playerCommand('play')", completionHandler: nil) }
    func pause() { webView.evaluateJavaScript("window.playerCommand('pause')", completionHandler: nil) }
    func stop()  { webView.evaluateJavaScript("window.playerCommand('stop')", completionHandler: nil) }
}

// MARK: - WKNavigationDelegate

extension ShakaDRMEngine: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        htmlLoaded = true
        pendingLoad?()
        pendingLoad = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        onEvent?(.error(code: -4, message: "WebView load failed: \(error.localizedDescription)"))
    }
}

// MARK: - WKScriptMessageHandler

extension ShakaDRMEngine: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "playerBridge",
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }

        switch type {
        case "ready":
            onEvent?(.ready)
        case "log":
            if let msg = body["message"] as? String { onEvent?(.log(msg)) }
        case "error":
            let code = body["code"] as? Int ?? -99
            let msg = body["message"] as? String ?? "unknown"
            onEvent?(.error(code: code, message: msg))
        case "state":
            if let s = body["state"] as? String { onEvent?(.state(s)) }
        default:
            break
        }
    }
}

// MARK: - SwiftUI wrapper

struct ShakaDRMPlayerView: UIViewRepresentable {
    let engine: ShakaDRMEngine

    func makeUIView(context: Context) -> WKWebView {
        engine.webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
