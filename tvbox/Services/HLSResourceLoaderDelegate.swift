import Foundation
import AVFoundation

/// 拦截并代理自定义 HLS 协议请求 (`tvbox-hls://`)
/// 在内存中清洗 m3u8 播放列表，将内部失效的 HTTPS TS 分片和 Key 转换为可直接访问的 HTTP，
/// 彻底避免使用本地 `file:///` 沙盒文件导致 AVPlayer 无法加载远程资源的阻塞问题。
final class HLSResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate {
    static let customScheme = "tvbox-hls"
    
    private let session: URLSession
    
    override init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: configuration)
        super.init()
    }
    
    // MARK: - AVAssetResourceLoaderDelegate
    
    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let requestURL = loadingRequest.request.url,
              requestURL.scheme?.lowercased() == Self.customScheme else {
            return false
        }
        
        // 将自定义 scheme 恢复为真实的 https (或 http)
        guard var components = URLComponents(url: requestURL, resolvingAgainstBaseURL: false) else {
            return false
        }
        components.scheme = "https"
        guard let realURL = components.url else {
            return false
        }
        
        Task {
            do {
                var urlRequest = URLRequest(url: realURL)
                urlRequest.timeoutInterval = 10
                urlRequest.setValue(
                    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
                    forHTTPHeaderField: "User-Agent"
                )
                if let host = realURL.host {
                    urlRequest.setValue("https://\(host)/", forHTTPHeaderField: "Referer")
                }
                
                let (data, response) = try await self.session.data(for: urlRequest)
                
                guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                    loadingRequest.finishLoading(with: NSError(
                        domain: "HLSResourceLoaderErrorDomain",
                        code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                        userInfo: [NSLocalizedDescriptionKey: "HTTP request failed"]
                    ))
                    return
                }
                
                // 处理并清洗播放列表内容
                let finalData: Data
                if let text = String(data: data, encoding: .utf8), text.contains("#EXTM3U") {
                    let serverPort = await LocalPlaybackProxyServer.shared.start()
                    var modifiedText = text
                    if serverPort > 0 {
                        let lines = modifiedText.components(separatedBy: "\n")
                        var newLines: [String] = []
                        for line in lines {
                            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                            if trimmed.hasPrefix("#EXT-X-KEY:") {
                                let keyPattern = #"URI="([^"]+)""#
                                if let regex = try? NSRegularExpression(pattern: keyPattern),
                                   let match = regex.firstMatch(in: trimmed, options: [], range: NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)),
                                   let uriRange = Range(match.range(at: 1), in: trimmed) {
                                    let originalURI = String(trimmed[uriRange])
                                    let absoluteURI = URL(string: originalURI, relativeTo: realURL)?.absoluteString ?? originalURI
                                    let encoded = absoluteURI.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? absoluteURI
                                    let proxyURI = "http://127.0.0.1:\(serverPort)/segment?url=\(encoded)"
                                    let replaced = trimmed.replacingOccurrences(of: "URI=\"\(originalURI)\"", with: "URI=\"\(proxyURI)\"")
                                    newLines.append(replaced)
                                    continue
                                }
                            } else if !trimmed.hasPrefix("#") && !trimmed.isEmpty {
                                let absolute = URL(string: trimmed, relativeTo: realURL)?.absoluteString ?? trimmed
                                if absolute.contains("zdmhyg.cn") {
                                    let encoded = absolute.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? absolute
                                    newLines.append("http://127.0.0.1:\(serverPort)/segment?url=\(encoded)")
                                    continue
                                }
                            }
                            newLines.append(line)
                        }
                        modifiedText = newLines.joined(separator: "\n")
                    }
                    finalData = modifiedText.data(using: .utf8) ?? data
                } else {
                    finalData = data
                }
                
                // 填充响应信息并返回数据
                if let contentInformationRequest = loadingRequest.contentInformationRequest {
                    contentInformationRequest.contentType = "application/vnd.apple.mpegurl"
                    contentInformationRequest.isByteRangeAccessSupported = false
                    contentInformationRequest.contentLength = Int64(finalData.count)
                }
                
                if let dataRequest = loadingRequest.dataRequest {
                    dataRequest.respond(with: finalData)
                }
                
                loadingRequest.finishLoading()
            } catch {
                loadingRequest.finishLoading(with: error)
            }
        }
        
        return true
    }
    
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        // 请求被取消时系统自动释放
    }
}
