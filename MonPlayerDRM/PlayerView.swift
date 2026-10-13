import SwiftUI

struct PlayerView: View {
    let channel: Channel

    @State private var engine: ShakaDRMEngine?
    @State private var status = "Đang khởi tạo player..."

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let engine {
                    ShakaDRMPlayerView(engine: engine)
                } else {
                    ProgressView().tint(.white)
                }
            }

            // Thanh trạng thái gọn dưới video
            HStack {
                if channel.hasDRM {
                    Text("DRM").font(.caption2).bold()
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.orange.opacity(0.25)).cornerRadius(4)
                }
                Text(status).font(.footnote).foregroundColor(.secondary).lineLimit(1)
                Spacer()
            }
            .padding(8)
        }
        .navigationTitle(channel.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { setup() }
        .onDisappear { engine?.stop() }
    }

    private func setup() {
        guard engine == nil else { return }
        let e = ShakaDRMEngine()
        e.onEvent = { event in
            DispatchQueue.main.async {
                switch event {
                case .ready:
                    self.status = "Player sẵn sàng"
                case .log(let msg):
                    print("[Shaka] \(msg)")
                case .error(let code, let message):
                    self.status = "Lỗi (\(code)): \(message)"
                case .state(let s):
                    switch s {
                    case "playing": self.status = "Đang phát"
                    case "paused": self.status = "Tạm dừng"
                    case "buffering": self.status = "Đang tải..."
                    case "ended": self.status = "Kết thúc"
                    default: break
                    }
                }
            }
        }
        engine = e
        e.loadPlayerPage()

        guard let streamURL = URL(string: channel.url) else {
            status = "URL stream không hợp lệ"
            return
        }

        Task {
            do {
                var clearKeys: [String: String]? = nil
                if let licenseURL = channel.licenseURL {
                    DispatchQueue.main.async { self.status = "Đang lấy key DRM..." }
                    let keySet = try await ClearKeyLicenseResolver.fetch(from: licenseURL)
                    clearKeys = keySet.keys
                    print("[DRM] lấy được \(keySet.keys.count) key")
                }
                DispatchQueue.main.async { self.status = "Đang tải stream..." }
                e.load(streamURL: streamURL, clearKeys: clearKeys, headers: channel.headers)
            } catch {
                DispatchQueue.main.async {
                    self.status = "Lỗi DRM: \(error.localizedDescription)"
                }
            }
        }
    }
}
