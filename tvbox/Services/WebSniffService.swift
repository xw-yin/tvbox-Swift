import Foundation
import WebKit
#if os(iOS)
import UIKit
#endif

/// 网页嗅探错误。
enum WebSniffError: Error, LocalizedError {
    case invalidURL(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "嗅探地址无效：\(url)"
        case .timeout:
            return "嗅探超时，未发现视频地址"
        }
    }
}

/// type=0 解析接口的网页嗅探服务（对应 Android 端 WebView 嗅探）。
///
/// 工作原理：用无头 WKWebView 加载 `解析接口URL + 待解析地址`，通过三路捕获
/// 真实播放地址，命中任一路即取消加载并返回：
/// 1. `decidePolicyFor navigationResponse`：响应 MIME 为视频类型；
/// 2. `decidePolicyFor navigationAction`：页面跳转/重定向到视频 URL；
/// 3. JS 轮询兜底：扫描 `<video>` 标签与 Performance Resource Timing 条目。
///
/// 注意：调用方无需关心线程，内部自动切到 MainActor。
@MainActor
final class WebSniffService: NSObject {
    static let shared = WebSniffService()

    /// 视为直链视频的扩展名集合。
    private static let videoExtensions: Set<String> = [
        "m3u8", "m3u", "mp4", "flv", "ts", "mpd", "m4s",
        "avi", "mkv", "mov", "wmv", "mpg", "mpeg", "webm"
    ]

    /// 进行中的嗅探会话（强持有，防止中途释放）。全在 MainActor 上访问，无需锁。
    private var activeSessions: [UUID: SniffSession] = [:]

    private override init() {}

    /// 执行一次嗅探。
    /// - Parameters:
    ///   - parseUrl: 解析接口 URL 前缀（Android 语义：直接拼接在目标地址前）。
    ///   - targetUrl: 待解析的原始播放地址。
    ///   - userAgent: 可选 UA，部分嗅探页需要桌面/移动 UA 才能吐出视频。
    ///   - timeout: 超时秒数，默认 25 秒。
    /// - Returns: 嗅探到的真实播放地址。
    func sniff(
        parseUrl: String,
        targetUrl: String,
        userAgent: String? = nil,
        timeout: TimeInterval = 25
    ) async throws -> String {
        let full = parseUrl + targetUrl
        guard let url = URL(string: full) else {
            throw WebSniffError.invalidURL(full)
        }
        return try await runSniff(url: url, userAgent: userAgent, timeout: timeout)
    }

    private func runSniff(url: URL, userAgent: String?, timeout: TimeInterval) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let session = SniffSession(
                url: url,
                userAgent: userAgent,
                timeout: timeout
            ) { [weak self] id, result in
                self?.releaseSession(id)
                continuation.resume(with: result)
            }
            self.retainSession(session)
            session.start()
        }
    }

    private func retainSession(_ session: SniffSession) {
        activeSessions[session.id] = session
    }

    fileprivate func releaseSession(_ id: UUID) {
        activeSessions.removeValue(forKey: id)
    }

    // MARK: - 判定辅助

    fileprivate static func isVideoURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        return videoExtensions.contains(ext)
    }

    fileprivate static func isVideoResponse(_ response: URLResponse, url: URL) -> Bool {
        if isVideoURL(url) { return true }
        guard let mime = response.mimeType?.lowercased() else { return false }
        return mime.hasPrefix("video/")
            || mime == "application/x-mpegurl"
            || mime == "application/vnd.apple.mpegurl"
            || mime == "application/dash+xml"
    }
}

// MARK: - 嗅探会话

/// 单次嗅探的完整生命周期持有者：WebView、轮询任务、超时任务。
@MainActor
private final class SniffSession: NSObject, WKNavigationDelegate {
    let id = UUID()

    private let url: URL
    private let userAgent: String?
    private let timeout: TimeInterval
    private let onResult: (UUID, Result<String, Error>) -> Void

    private var webView: WKWebView?
    #if os(iOS)
    private var window: UIWindow?
    #endif
    private var finished = false
    private var pollTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    init(
        url: URL,
        userAgent: String?,
        timeout: TimeInterval,
        onResult: @escaping (UUID, Result<String, Error>) -> Void
    ) {
        self.url = url
        self.userAgent = userAgent
        self.timeout = timeout
        self.onResult = onResult
    }

    func start() {
        let config = WKWebViewConfiguration()
        // 允许自动播放，便于嗅探页触发视频加载。
        config.mediaTypesRequiringUserActionForPlayback = []
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        if let ua = userAgent, !ua.isEmpty {
            webView.customUserAgent = ua
        }
        self.webView = webView

        #if os(iOS)
        // 移出屏幕的 1x1 窗口：WebView 需要宿主窗口才能正常执行 JS 定时器。
        let win = UIWindow(frame: CGRect(x: -10, y: -10, width: 1, height: 1))
        win.windowLevel = .normal
        win.addSubview(webView)
        win.isHidden = false
        self.window = win
        #endif

        webView.load(URLRequest(url: url))
        startPolling()
        startTimeout()
    }

    // MARK: - 结束

    private func finish(_ result: Result<String, Error>) {
        guard !finished else { return }
        finished = true
        pollTask?.cancel()
        timeoutTask?.cancel()
        pollTask = nil
        timeoutTask = nil
        if let webView {
            webView.stopLoading()
            webView.navigationDelegate = nil
        }
        webView = nil
        #if os(iOS)
        window?.isHidden = true
        window = nil
        #endif
        onResult(id, result)
    }

    private func startTimeout() {
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(self?.timeout ?? 25) * 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.finish(.failure(WebSniffError.timeout))
        }
    }

    // MARK: - JS 轮询兜底

    private func startPolling() {
        pollTask = Task { [weak self] in
            // 首轮稍作等待，让页面有机会开始加载。
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            while let self, !Task.isCancelled {
                if let hit = await self.probeVideoURLs().first {
                    self.finish(.success(hit))
                    return
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    /// 用 JS 扫描 video 标签与资源加载条目，返回命中的视频 URL。
    private func probeVideoURLs() async -> [String] {
        guard let webView else { return [] }
        let js = """
        (() => {
          const urls = [];
          const push = u => { if (u && typeof u === 'string' && u.startsWith('http')) urls.push(u); };
          document.querySelectorAll('video').forEach(v => {
            push(v.currentSrc || v.src);
            v.querySelectorAll('source').forEach(s => push(s.src));
          });
          try {
            performance.getEntriesByType('resource').forEach(r => {
              const u = (r.name || '').toLowerCase();
              if (/\\.(m3u8|m3u|mp4|flv|ts|mpd|m4s|avi|mkv|mov|webm)([?#]|$)/.test(u)) push(r.name);
            });
          } catch (e) {}
          return [...new Set(urls)].slice(0, 10).join('\\n');
        })()
        """
        do {
            let raw = try await webView.evaluateJavaScript(js)
            guard let text = raw as? String, !text.isEmpty else { return [] }
            return text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        } catch {
            return []
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if let url = navigationAction.request.url,
           WebSniffService.isVideoURL(url) {
            decisionHandler(.cancel)
            finish(.success(url.absoluteString))
            return
        }
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        if let url = navigationResponse.response.url,
           WebSniffService.isVideoResponse(navigationResponse.response, url: url) {
            decisionHandler(.cancel)
            finish(.success(url.absoluteString))
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        // 子资源失败不直接判负，交给超时兜底；仅记录。
        print("嗅探页加载异常: \(error.localizedDescription)")
    }
}
