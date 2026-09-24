import Foundation

/// 解析链路错误
enum ParseChainError: LocalizedError {
    /// 播放地址为空
    case emptyURL
    /// 配置中没有可用的解析接口
    case noParses
    /// 所有解析接口均尝试失败（关联已尝试数量）
    case allFailed(Int)
    /// 单个解析接口请求超时
    case timeout

    var errorDescription: String? {
        switch self {
        case .emptyURL:
            return "播放地址为空"
        case .noParses:
            return "当前配置没有可用的解析接口"
        case .allFailed(let count):
            return "尝试了 \(count) 个解析接口，均未还原出可播放地址"
        case .timeout:
            return "解析接口请求超时"
        }
    }
}

/// 解析链路服务 - 对应 Android 版播放解析/嗅探链路
///
/// 当剧集地址不是可直接播放的媒体直链时（如站点只给了需要还原的页面地址），
/// 按配置中的解析接口列表逐个尝试，还原出真实可播放地址。
///
/// - type=1（JSON 解析接口）：完整支持，兼容标准 JSON 与 JSONP 包裹返回，
///   并兼容纯文本直链返回。
/// - type=0（嗅探接口）：经由 WebSniffService 用无头 WKWebView 真实加载页面，
///   通过响应 MIME / 跳转 / JS 轮询三路嗅探媒体地址。
///
/// 附加能力：按各解析接口的历史成功延迟做滑动平均统计，
/// 下次优先尝试历史上更快的接口。
enum ParseChainService {
    /// 单个解析接口超时（秒）。
    private static let perParseTimeout: TimeInterval = 12
    /// 解析延迟统计持久化 key（毫秒，滑动平均）。
    private static let latencyStatsKey = "TVBoxParseLatencyStats"

    /// 可直接播放的媒体后缀。
    private static let playableExtensions: Set<String> = [
        "m3u8", "mp4", "m4v", "mov", "mkv", "avi", "flv",
        "ts", "m2ts", "webm", "mpd", "mp3", "m4a", "aac", "wav", "ogg",
    ]
    /// 无后缀流地址的常见特征。
    private static let playableHints = ["m3u8", ".mp4", "mime=video"]

    // MARK: - 直链判定

    /// 判断地址是否为可直接播放的媒体直链。
    static func isDirectlyPlayable(_ urlString: String) -> Bool {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lower = trimmed.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { return false }
        if playableHints.contains(where: { lower.contains($0) }) { return true }
        guard let url = URL(string: trimmed) else { return false }
        return playableExtensions.contains(url.pathExtension.lowercased())
    }

    // MARK: - 解析链路

    /// 按序尝试解析接口，还原可播放地址。
    ///
    /// - Parameter urlString: 原始剧集地址。
    /// - Returns: 还原后的可播放地址，以及本次命中的解析接口名称（用于 UI 展示）。
    /// - Throws: 解析接口为空或全部失败时抛出 `ParseChainError`。
    @MainActor
    static func resolve(_ urlString: String) async throws -> (url: String, parseName: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ParseChainError.emptyURL }

        let parses = ApiConfig.shared.parseBeanList
        guard !parses.isEmpty else { throw ParseChainError.noParses }

        // 按历史延迟优选：越快越靠前；未统计过的保持原相对顺序。
        let stats = loadLatencyStats()
        let ordered = parses.enumerated()
            .sorted { lhs, rhs in
                let l0 = stats[lhs.element.name] ?? Double.infinity
                let l1 = stats[rhs.element.name] ?? Double.infinity
                if l0 != l1 { return l0 < l1 }
                return lhs.offset < rhs.offset
            }
            .map { $0.element }

        var attempted = 0
        for parse in ordered {
            try Task.checkCancellation()
            let parseURL = parse.url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !parseURL.isEmpty else { continue }

            attempted += 1
            let startedAt = Date()
            do {
                let playable: String?
                if parse.type == 0 {
                    // 嗅探接口：无头 WebView 真实加载页面嗅探媒体地址。
                    let ua = parse.ext?["ua"]
                    playable = try await WebSniffService.shared.sniff(
                        parseUrl: parseURL,
                        targetUrl: trimmed,
                        userAgent: ua,
                        timeout: 25
                    )
                } else {
                    // 与 Android 端保持一致：解析接口地址直接拼接原始地址。
                    let target = parseURL + trimmed
                    let text = try await withTimeout(seconds: perParseTimeout) {
                        try await NetworkManager.shared.getString(from: target, maxRetries: 0)
                    }
                    playable = extractPlayableURL(from: text)
                }
                if let playable, isDirectlyPlayable(playable) {
                    recordLatency(for: parse.name, seconds: Date().timeIntervalSince(startedAt))
                    return (url: playable, parseName: parse.name)
                }
            } catch {
                // 单个接口失败继续尝试下一个。
                continue
            }
        }
        throw ParseChainError.allFailed(attempted)
    }

    // MARK: - 解析结果提取

    /// 从解析接口返回文本中提取可播放地址。
    ///
    /// 兼容三种常见返回形态：
    /// 1. 纯文本直链；
    /// 2. 标准 JSON（如 `{"url": "..."}` 或 `{"data": {"url": "..."}}`）；
    /// 3. JSONP 包裹（如 `jQuery123({"url": "..."})`）。
    private static func extractPlayableURL(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 纯文本直链
        if trimmed.lowercased().hasPrefix("http"), !trimmed.contains("{") {
            return trimmed
        }

        // 兼容 JSONP：截取首个 { 到末个 } 之间的 JSON 片段
        let jsonText: String
        if trimmed.hasPrefix("{") {
            jsonText = trimmed
        } else if let left = trimmed.firstIndex(of: "{"),
                  let right = trimmed.lastIndex(of: "}"),
                  left < right {
            jsonText = String(trimmed[left...right])
        } else {
            return nil
        }

        guard let data = jsonText.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let url = obj["url"] as? String, !url.isEmpty { return url }
        if let nested = obj["data"] as? [String: Any],
           let url = nested["url"] as? String, !url.isEmpty { return url }
        return nil
    }

    // MARK: - 超时控制

    /// 带超时的异步执行，超时后取消原任务并抛出 `ParseChainError.timeout`。
    private static func withTimeout<T>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw ParseChainError.timeout
            }
            guard let result = try await group.next() else {
                throw ParseChainError.timeout
            }
            group.cancelAll()
            return result
        }
    }

    // MARK: - 延迟统计

    /// 读取各解析接口的历史延迟（毫秒）。
    private static func loadLatencyStats() -> [String: Double] {
        UserDefaults.standard.dictionary(forKey: latencyStatsKey) as? [String: Double] ?? [:]
    }

    /// 记录一次解析成功延迟（滑动平均，避免单次抖动主导排序）。
    private static func recordLatency(for parseName: String, seconds: Double) {
        guard !parseName.isEmpty else { return }
        var stats = loadLatencyStats()
        let millis = seconds * 1000
        if let previous = stats[parseName] {
            stats[parseName] = previous * 0.7 + millis * 0.3
        } else {
            stats[parseName] = millis
        }
        UserDefaults.standard.set(stats, forKey: latencyStatsKey)
    }
}
