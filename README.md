# MonPlayer DRM

App iOS xem IPTV, phát được kênh **DRM ClearKey** (DASH/HLS) bằng engine
**Shaka Player trong WKWebView** — kiến trúc đã verify chạy thực tế với
playlist VietAnhTV (kênh HBO, OnSport+, OnSport, On Football...).

## Tính năng

- Nhập link playlist `.m3u` -> liệt kê kênh (tên, logo, tìm kiếm)
- Kênh thường: phát trực tiếp qua Shaka
- Kênh DRM: tự đọc `#KODIPROP...license_key=` trong playlist, fetch ClearKey
  từ key server của nhà cung cấp (kèm User-Agent IPTV), giải mã qua EME
- Gắn header (`User-Agent`, `Referer`...) từ `#EXTVLCOPT` vào mọi request

## DRM hỗ trợ

| DRM | Trạng thái trên iOS |
|---|---|
| ClearKey | ✅ (engine này) |
| FairPlay | ✅ (đã để sẵn hook trong `drm-player.js`, cần FPS cert + license server) |
| AES-128 HLS | ✅ |
| Widevine / PlayReady | ❌ không có CDM trên iOS — không app nào làm được |

## Build

Mỗi lần push lên `main` (hoặc bấm Run workflow), GitHub Actions tự build
IPA **unsigned** và đăng lên Artifacts (`MonPlayerDRM-unsigned`).
Tải về rồi sideload (TrollStore / Sideloadly / AltStore...).

## Cấu trúc

```
MonPlayerDRM/
├── MonPlayerDRMApp.swift      # @main
├── ContentView.swift          # Nhập playlist, danh sách kênh
├── PlayerView.swift            # Màn hình phát
├── M3UParser.swift             # Parse M3U (EXTINF / EXTVLCOPT / KODIPROP)
├── ClearKeyLicense.swift       # Fetch + convert ClearKey cho Shaka
├── ShakaDRMEngine.swift        # WKWebView + bridge JS <-> Swift
├── drm-player.html / .js       # Host page + Shaka glue
├── shaka-player.ui.js          # Shaka Player v4.7.0 — tải lúc build (pin version trong workflow)
└── Info.plist
```
