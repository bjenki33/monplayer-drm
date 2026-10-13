// drm-player.js
// Engine DRM cho MonPlayer: Shaka Player trong WKWebView.
//
// Luồng:
//   Native (Swift) -> window.loadChannel(jsonString)
//     json: { url, drmKeys?: {kidHex: keyHex}, headers?: {k: v} }
//   JS -> window.webkit.messageHandlers.playerBridge.postMessage({type, ...})
//     type: ready | log | error | state
//
// DRM hỗ trợ:
//   - ClearKey: drmKeys (kid hex -> key hex), qua EME org.w3.clearkey
//   - FairPlay: cấu hình thêm bên dưới (cần FPS certificate + license server)
//   - Widevine: KHÔNG có trên iOS (không CDM) -> đừng cố

(function () {
    'use strict';

    const video = document.getElementById('video');
    let player = null;
    let isReady = false;
    let pendingChannel = null;
    let currentHeaders = {};
    let loadGeneration = 0;

    function notify(type, payload) {
        try {
            window.webkit.messageHandlers.playerBridge.postMessage(
                Object.assign({ type }, payload || {})
            );
        } catch (_) { /* chạy ngoài WKWebView (debug browser) thì bỏ qua */ }
    }

    function log(msg) { notify('log', { message: String(msg) }); }

    function reportError(err) {
        const code = err && err.code;
        // Bỏ qua lỗi do load() bị ngắt khi chuyển kênh nhanh
        if (code === 7001) return; // shaka.util.Error.Code.LOAD_INTERRUPTED
        let msg = 'unknown';
        try { msg = String((err && err.message) || err); } catch (_) {}
        notify('error', { code: code || -99, message: msg });
        log('[Error] code=' + code + ' msg=' + msg);
    }

    // Gắn header (User-Agent, Referer, Origin...) vào MỌI request của Shaka.
    function applyRequestFilter() {
        try {
            player.getNetworkingEngine().registerRequestFilter((type, request) => {
                for (const k of Object.keys(currentHeaders)) {
                    request.headers[k] = currentHeaders[k];
                }
            });
        } catch (e) { log('[Warn] requestFilter: ' + e); }
    }

    async function initPlayer() {
        try {
            shaka.polyfill.installAll();
            if (!shaka.Player.isBrowserSupported()) {
                notify('error', { code: -10, message: 'Shaka không hỗ trợ trên WebView này' });
                return;
            }
            player = new shaka.Player();
            await player.attach(video);
            applyRequestFilter();

            player.addEventListener('error', (e) => reportError(e.detail));

            // State báo về native để update UI (spinner, nút play/pause...)
            video.addEventListener('playing', () => notify('state', { state: 'playing' }));
            video.addEventListener('pause', () => notify('state', { state: 'paused' }));
            video.addEventListener('waiting', () => notify('state', { state: 'buffering' }));
            video.addEventListener('ended', () => notify('state', { state: 'ended' }));

            isReady = true;
            notify('ready', {});
            log('[Shaka] ready, version=' + shaka.Player.version);

            if (pendingChannel) {
                const ch = pendingChannel;
                pendingChannel = null;
                void loadChannelInternal(ch);
            }
        } catch (e) {
            reportError(e);
        }
    }

    async function loadChannelInternal(channel) {
        const generation = ++loadGeneration;
        const url = channel.url;
        const drmKeys = channel.drmKeys || {};
        const keyCount = Object.keys(drmKeys).length;
        currentHeaders = channel.headers || {};

        log('[Load] url=' + url + ' clearKeys=' + keyCount);

        try { video.pause(); } catch (_) {}
        try { await player.detach(); } catch (_) {}
        if (generation !== loadGeneration) return;
        try { await player.attach(video); } catch (_) {}
        if (generation !== loadGeneration) return;
        applyRequestFilter(); // detach() reset networking engine -> đăng ký lại

        player.resetConfiguration();

        // ABR bật để hình/mượt tự theo mạng
        player.configure({ abr: { enabled: true } });

        if (keyCount > 0) {
            // ===== ClearKey qua EME =====
            // drmKeys: { kidHex (lowercase, không gạch ngang): keyHex }
            // Format này theo đúng Shaka docs: "map of key IDs to content keys (both in hex)"
            player.configure({
                drm: {
                    clearKeys: drmKeys,
                    servers: {},
                    // Bỏ qua DRM info trong manifest, ép dùng clearKeys đã cấp.
                    // (Hữu ích khi manifest ghi key system lạ nhưng thực chất là ClearKey)
                },
                manifest: { ignoreDrmInfo: true },
            });
            log('[DRM] ClearKey kids=' + JSON.stringify(Object.keys(drmKeys)));
        } else {
            player.configure({ manifest: { ignoreDrmInfo: false } });
        }

        // ===== FairPlay (để dành tương lai) =====
        // Khi nào mày có FPS certificate + license server thì mở comment:
        //
        // player.configure({
        //     drm: {
        //         servers: { 'com.apple.fps': 'https://license.example.com/fairplay' },
        //         advanced: {
        //             'com.apple.fps': {
        //                 serverCertificateUri: 'https://license.example.com/fairplay/cert',
        //             },
        //         },
        //     },
        // });
        // Lưu ý: FairPlay cần Apple FPS Deployment Package (xin từ Apple),
        // content phải đóng gói cbcs. Không phải cứ có URL là chạy.

        if (generation !== loadGeneration) return;
        await player.load(url);
        if (generation !== loadGeneration) return;

        try { await video.play(); } catch (e) { log('[Warn] autoplay: ' + e); }
        log('[Load] done');
    }

    // Native gọi: window.loadChannel('{"url":"...","drmKeys":{...},"headers":{...}}')
    window.loadChannel = function (jsonString) {
        let channel;
        try {
            channel = JSON.parse(jsonString);
        } catch (e) {
            notify('error', { code: -11, message: 'JSON channel không hợp lệ' });
            return;
        }
        if (!channel || !channel.url) {
            notify('error', { code: -12, message: 'Thiếu url' });
            return;
        }
        if (!isReady || !player) {
            pendingChannel = channel; // queue, chạy khi Shaka ready
            return;
        }
        void loadChannelInternal(channel);
    };

    // Native gọi: window.playerCommand('play' | 'pause' | 'stop')
    window.playerCommand = function (cmd) {
        try {
            if (cmd === 'play') video.play().catch(() => {});
            else if (cmd === 'pause') video.pause();
            else if (cmd === 'stop') { video.pause(); video.removeAttribute('src'); }
        } catch (_) {}
    };

    document.addEventListener('DOMContentLoaded', initPlayer);
    // Trường hợp script load sau DOMContentLoaded
    if (document.readyState !== 'loading') initPlayer();
})();
