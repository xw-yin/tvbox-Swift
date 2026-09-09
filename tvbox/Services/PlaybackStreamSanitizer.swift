import Foundation

/// 媒体流与播放地址容错清洗服务
/// 针对部分源（如黄果短剧等）顶层 m3u8 内部分片/Key 指向无证书/TLS 握手失败的 CDN 域名（如 *.zdmhyg.cn）时，
/// 在本地自动将失效的 https 转换为可正常访问的 http，生成本地安全流或修复直链，避免播放器发生 -1200 / -1202 错误。
actor PlaybackStreamSanitizer {
    static let shared = PlaybackStreamSanitizer()
    
    /// 已知无有效 443 TLS 证书/TLS 握手重置的 CDN 域名规则
    private static let brokenTLSHostPatterns: [String] = [
        #"https://(tp\d*\.zdmhyg\.cn)"#
    ]
    
    private init() {
        cleanOldTempFiles()
    }
    
    /// 预处理并清洗播放直链
    /// - Parameter urlString: 原始流地址
    /// - Returns: 可正常播放的直链（若检测到需要清洗的 m3u8，则返回清洗后的本地安全 m3u8 地址；否则返回原地址）
    func preparePlayableURL(from urlString: String) async -> String {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return urlString }
        
        // 1. 如果自身是已知无 TLS 的 HTTPS 直链，直接降级为 HTTP
        var directFixed = trimmed
        for pattern in Self.brokenTLSHostPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(directFixed.startIndex..<directFixed.endIndex, in: directFixed)
                directFixed = regex.stringByReplacingMatches(in: directFixed, options: [], range: range, withTemplate: "http://$1")
            }
        }
        
        // 2. 如果包含 m3u8 且指向可能含有非法内部 TLS 分片的域名，抓取内容并清洗
        let isM3U8 = directFixed.contains(".m3u8") || directFixed.contains("/m3u8")
        let isPotentiallyAffected = directFixed.contains("zdmhyg.cn") || directFixed.contains("hrppxr.cn")
        
        guard isM3U8 && isPotentiallyAffected, let url = URL(string: directFixed) else {
            return directFixed
        }
        
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
                forHTTPHeaderField: "User-Agent"
            )
            if let host = url.host {
                request.setValue("https://\(host)/", forHTTPHeaderField: "Referer")
            }
            
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode),
               let text = String(data: data, encoding: .utf8), text.contains("#EXTM3U") {
                
                // 检查 m3u8 内容是否包含失效的 TLS 链接
                var modifiedText = text
                var hasModifications = false
                
                for pattern in Self.brokenTLSHostPatterns {
                    if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                        let range = NSRange(modifiedText.startIndex..<modifiedText.endIndex, in: modifiedText)
                        let replaced = regex.stringByReplacingMatches(in: modifiedText, options: [], range: range, withTemplate: "http://$1")
                        if replaced != modifiedText {
                            modifiedText = replaced
                            hasModifications = true
                        }
                    }
                }
                
                if hasModifications {
                    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("m3u8_sanitized", isDirectory: true)
                    try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                    let fileURL = tempDir.appendingPathComponent("stream_\(UUID().uuidString).m3u8")
                    try modifiedText.write(to: fileURL, atomically: true, encoding: .utf8)
                    return fileURL.absoluteString
                }
            }
        } catch {
            print("[PlaybackStreamSanitizer] Pre-sanitization skipped or failed: \(error)")
        }
        
        return directFixed
    }
    
    /// 当播放器遇到 TLS/SSL 错误时，尝试对任意 m3u8 URL 进行全面 HTTP 降级与内部清洗重试
    func forceFallbackSanitization(for urlString: String) async -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else { return nil }
        
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
                forHTTPHeaderField: "User-Agent"
            )
            
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode),
               let text = String(data: data, encoding: .utf8), text.contains("#EXTM3U") {
                
                // 将所有非标准/可能导致握手失败的 https 强制降级为 http
                let fixedText = text.replacingOccurrences(of: "https://", with: "http://")
                
                let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("m3u8_sanitized", isDirectory: true)
                try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                let fileURL = tempDir.appendingPathComponent("stream_fallback_\(UUID().uuidString).m3u8")
                try fixedText.write(to: fileURL, atomically: true, encoding: .utf8)
                return fileURL.absoluteString
            }
        } catch {
            // 如果 m3u8 本身直接换成 http 能通
            if trimmed.lowercased().hasPrefix("https://") {
                return "http://" + trimmed.dropFirst(8)
            }
        }
        
        return nil
    }
    
    /// 清理 1 小时前的临时播放列表文件，防止磁盘占用
    private func cleanOldTempFiles() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("m3u8_sanitized", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return
        }
        let oneHourAgo = Date().addingTimeInterval(-3600)
        for file in files {
            if let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               date < oneHourAgo {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
