import Foundation
import Network
import Security

/// 本地回环媒体流代理服务 (Local Loopback Media Stream Proxy)
///
/// 核心解决部分 CDN / 影视源（如黄果短剧等）存在的严重 TLS/SNI 配置缺陷：
/// 1. 部分源的 m3u8 内切片与解密密钥域名（如 *.zdmhyg.cn）托管在 CDN 上，但 CDN 未配置部署该域名证书。
/// 2. 现代播放器（AVPlayer / VLC）发起 HTTPS 握手时携带该 SNI 会直接被 CDN 掐断连接（报 -1200 / -1202 错误）。
/// 3. 若直接降级为 HTTP 80 端口，又会被运营商机房因未备案而 302 劫持至拦截页。
///
/// 本服务在本地 127.0.0.1 动态端口运行轻量代理：
/// - 拦截并清洗 m3u8 播放列表，将密钥和分片请求代理到本地回环地址；
/// - 在抓取异常 CDN 资源时，通过 IP 直连规避非法 SNI 扩展，同时绕过无效证书校验，确保 AVPlayer 与 VLC 均能平滑播放。
final class LocalPlaybackProxyServer: @unchecked Sendable {
    static let shared = LocalPlaybackProxyServer()
    
    /// 已知无有效 443 TLS 证书/TLS 握手重置的 CDN 域名规则（针对该类域名发起无 SNI 直连）
    static let brokenTLSHostPatterns: [String] = [
        #".*\.zdmhyg\.cn"#
    ]
    
    /// 静态兜底解析 IP（当系统 DNS 与 DoH 均受阻时保障可用）
    private static let staticFallbackIPs: [String: String] = [
        "tp4.zdmhyg.cn": "27.159.90.74",
        "tp.zdmhyg.cn": "27.159.90.74",
        "pic.zdmhyg.cn": "27.159.90.74"
    ]
    
    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    private let queue = DispatchQueue(label: "com.tvbox.playbackproxyserver", qos: .userInitiated)
    private var isStarting = false
    private var startContinuations: [CheckedContinuation<UInt16, Never>] = []
    
    /// IP 解析缓存 (host -> (ip, expireDate))
    private var ipCache: [String: (ip: String, expire: Date)] = [:]
    private let cacheLock = NSLock()
    
    /// 忽略证书校验的专用 URLSession
    private lazy var insecureSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 60
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: InsecureSSLSessionDelegate(), delegateQueue: nil)
    }()
    
    private init() {}
    
    // MARK: - 启动与状态管理
    
    /// 启动本地代理服务并获取监听端口
    func start() async -> UInt16 {
        if port > 0, listener?.state == .ready {
            return port
        }
        
        return await withCheckedContinuation { continuation in
            queue.async {
                if self.port > 0, self.listener?.state == .ready {
                    continuation.resume(returning: self.port)
                    return
                }
                
                self.startContinuations.append(continuation)
                if self.isStarting { return }
                self.isStarting = true
                
                do {
                    let tcpOptions = NWProtocolTCP.Options()
                    tcpOptions.noDelay = true
                    let parameters = NWParameters(tls: nil, tcp: tcpOptions)
                    parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
                    parameters.allowLocalEndpointReuse = true
                    
                    let listener = try NWListener(using: parameters)
                    self.listener = listener
                    
                    listener.stateUpdateHandler = { [weak self] state in
                        guard let self = self else { return }
                        switch state {
                        case .ready:
                            if let assignedPort = listener.port?.rawValue {
                                self.port = assignedPort
                                self.isStarting = false
                                let continuations = self.startContinuations
                                self.startContinuations.removeAll()
                                for cont in continuations {
                                    cont.resume(returning: assignedPort)
                                }
                                #if DEBUG
                                print("[LocalPlaybackProxy] Ready on http://127.0.0.1:\(assignedPort)")
                                #endif
                            }
                        case .failed(let error):
                            #if DEBUG
                            print("[LocalPlaybackProxy] Listener failed: \(error)")
                            #endif
                            self.isStarting = false
                            listener.cancel()
                            let continuations = self.startContinuations
                            self.startContinuations.removeAll()
                            for cont in continuations {
                                cont.resume(returning: 0)
                            }
                        default:
                            break
                        }
                    }
                    
                    listener.newConnectionHandler = { [weak self] connection in
                        self?.handleIncomingConnection(connection)
                    }
                    
                    listener.start(queue: self.queue)
                } catch {
                    #if DEBUG
                    print("[LocalPlaybackProxy] Init failed: \(error)")
                    #endif
                    self.isStarting = false
                    let continuations = self.startContinuations
                    self.startContinuations.removeAll()
                    for cont in continuations {
                        cont.resume(returning: 0)
                    }
                }
            }
        }
    }
    
    /// 构建指向本地代理的 HLS 播放直链
    func buildProxyURL(for originalURL: String) async -> String? {
        let trimmed = originalURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        
        let serverPort = await start()
        guard serverPort > 0 else { return nil }
        
        guard let encodedTarget = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }
        
        return "http://127.0.0.1:\(serverPort)/hls?url=\(encodedTarget)"
    }
    
    // MARK: - 连接接收与 HTTP 解析
    
    private func handleIncomingConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveHTTPRequest(connection: connection, accumulated: Data())
    }
    
    private func receiveHTTPRequest(connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32768) { [weak self] content, _, isComplete, error in
            guard let self = self else { return }
            if error != nil {
                connection.cancel()
                return
            }
            
            var buffer = accumulated
            if let content = content {
                buffer.append(content)
            }
            
            // 检测 HTTP 头部结束标志 (\r\n\r\n 或 \n\n)
            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = buffer.subdata(in: 0..<headerEnd.lowerBound)
                if let headerText = String(data: headerData, encoding: .utf8) {
                    Task {
                        await self.dispatchHTTPRequest(headerText: headerText, connection: connection)
                    }
                    return
                }
            }
            
            if isComplete {
                connection.cancel()
            } else {
                self.receiveHTTPRequest(connection: connection, accumulated: buffer)
            }
        }
    }
    
    private func dispatchHTTPRequest(headerText: String, connection: NWConnection) async {
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, !requestLine.isEmpty else {
            connection.cancel()
            return
        }
        
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            connection.cancel()
            return
        }
        
        let pathAndQuery = parts[1]
        guard let components = URLComponents(string: pathAndQuery) else {
            sendHTTPResponse(status: 400, statusText: "Bad Request", headers: [:], body: Data(), to: connection)
            return
        }
        
        // 收集客户端请求头（如 Range）
        var clientHeaders: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colonIndex = line.firstIndex(of: ":") {
                let key = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                clientHeaders[key.lowercased()] = value
            }
        }
        
        let targetParam = components.queryItems?.first(where: { $0.name == "url" })?.value ?? ""
        guard let targetURL = URL(string: targetParam) else {
            sendHTTPResponse(status: 400, statusText: "Missing Target URL", headers: [:], body: Data("Missing url param".utf8), to: connection)
            return
        }
        
        let path = components.path
        if path == "/hls" {
            await handleHLSPlaylist(targetURL: targetURL, connection: connection)
        } else if path == "/segment" {
            await handleMediaSegment(targetURL: targetURL, clientHeaders: clientHeaders, connection: connection)
        } else {
            sendHTTPResponse(status: 404, statusText: "Not Found", headers: [:], body: Data(), to: connection)
        }
    }
    
    // MARK: - m3u8 播放列表清洗与改写
    
    private func handleHLSPlaylist(targetURL: URL, connection: NWConnection) async {
        do {
            let host = targetURL.host ?? ""
            let isBrokenTLSHost = isHostMatchingBrokenTLSPatterns(host)
            
            let data: Data
            if isBrokenTLSHost, let directIP = await resolveIP(for: host) {
                let directRes = try await fetchViaNoSNITLS(
                    targetIP: directIP,
                    hostHeader: host,
                    targetURL: targetURL,
                    clientHeaders: [:]
                )
                data = directRes.data
            } else {
                var request = URLRequest(url: targetURL)
                request.timeoutInterval = 12
                request.setValue(
                    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
                    forHTTPHeaderField: "User-Agent"
                )
                request.setValue("https://\(targetURL.host ?? "")/", forHTTPHeaderField: "Referer")
                
                let (resData, response) = try await insecureSession.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                    sendHTTPResponse(status: 502, statusText: "Bad Gateway", headers: [:], body: Data("Fetch playlist failed".utf8), to: connection)
                    return
                }
                data = resData
            }
            
            guard let playlistText = String(data: data, encoding: .utf8) else {
                sendHTTPResponse(status: 502, statusText: "Bad Gateway", headers: [:], body: Data("Decode playlist failed".utf8), to: connection)
                return
            }
            
            let rewrittenPlaylist = rewriteM3U8Content(playlistText, baseURL: targetURL)
            let responseData = rewrittenPlaylist.data(using: .utf8) ?? data
            
            let headers: [String: String] = [
                "Content-Type": "application/vnd.apple.mpegurl",
                "Content-Length": "\(responseData.count)",
                "Access-Control-Allow-Origin": "*",
                "Cache-Control": "no-cache"
            ]
            sendHTTPResponse(status: 200, statusText: "OK", headers: headers, body: responseData, to: connection)
        } catch {
            sendHTTPResponse(status: 500, statusText: "Internal Error", headers: [:], body: Data(error.localizedDescription.utf8), to: connection)
        }
    }
    
    /// 改写 m3u8 内部 Key 和分片链接为本地代理路由
    private func rewriteM3U8Content(_ content: String, baseURL: URL) -> String {
        let lines = content.components(separatedBy: "\n")
        var rewritten: [String] = []
        let currentPort = self.port
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                rewritten.append(line)
                continue
            }
            
            // 1. 匹配并改写 #EXT-X-KEY
            if trimmed.hasPrefix("#EXT-X-KEY:") {
                let keyPattern = #"URI="([^"]+)""#
                if let regex = try? NSRegularExpression(pattern: keyPattern),
                   let match = regex.firstMatch(in: trimmed, options: [], range: NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)),
                   let uriRange = Range(match.range(at: 1), in: trimmed) {
                    let originalURI = String(trimmed[uriRange])
                    let absoluteURI = URL(string: originalURI, relativeTo: baseURL)?.absoluteString ?? originalURI
                    let encoded = absoluteURI.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? absoluteURI
                    let proxyURI = "http://127.0.0.1:\(currentPort)/segment?url=\(encoded)"
                    let replacedLine = trimmed.replacingOccurrences(of: "URI=\"\(originalURI)\"", with: "URI=\"\(proxyURI)\"")
                    rewritten.append(replacedLine)
                    continue
                }
            }
            
            // 2. 匹配子变体播放列表 (*.m3u8)
            if !trimmed.hasPrefix("#") && (trimmed.contains(".m3u8") || trimmed.contains("/m3u8")) {
                let absolute = URL(string: trimmed, relativeTo: baseURL)?.absoluteString ?? trimmed
                let encoded = absolute.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? absolute
                rewritten.append("http://127.0.0.1:\(currentPort)/hls?url=\(encoded)")
                continue
            }
            
            // 3. 匹配媒体切片文件 (TS 分片等)
            if !trimmed.hasPrefix("#") {
                let absolute = URL(string: trimmed, relativeTo: baseURL)?.absoluteString ?? trimmed
                let encoded = absolute.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? absolute
                rewritten.append("http://127.0.0.1:\(currentPort)/segment?url=\(encoded)")
                continue
            }
            
            rewritten.append(line)
        }
        
        return rewritten.joined(separator: "\n")
    }
    
    // MARK: - 媒体分片 / Key 请求处理与 IP 直连 TLS 穿透
    
    private func handleMediaSegment(targetURL: URL, clientHeaders: [String: String], connection: NWConnection) async {
        let host = targetURL.host ?? ""
        let isBrokenTLSHost = isHostMatchingBrokenTLSPatterns(host)
        
        do {
            // 针对证书缺失的 CDN 域名，采用 NWConnection IP 直连且不发 SNI 扩展，彻底规避握手掐断
            if isBrokenTLSHost, let directIP = await resolveIP(for: host) {
                let response = try await fetchViaNoSNITLS(
                    targetIP: directIP,
                    hostHeader: host,
                    targetURL: targetURL,
                    clientHeaders: clientHeaders
                )
                
                sendHTTPResponse(
                    status: response.statusCode,
                    statusText: response.statusCode == 206 ? "Partial Content" : "OK",
                    headers: response.headers,
                    body: response.data,
                    to: connection
                )
                return
            }
            
            // 普通域名走标准 URLSession
            var request = URLRequest(url: targetURL)
            request.timeoutInterval = 25
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
                forHTTPHeaderField: "User-Agent"
            )
            request.setValue("https://\(host)/", forHTTPHeaderField: "Referer")
            
            // 透传 Range 头部支持切片 Seek / 快速缓冲
            if let rangeValue = clientHeaders["range"] {
                request.setValue(rangeValue, forHTTPHeaderField: "Range")
            }
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                sendHTTPResponse(status: 502, statusText: "Bad Gateway", headers: [:], body: Data(), to: connection)
                return
            }
            
            var responseHeaders: [String: String] = [
                "Content-Type": httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream",
                "Content-Length": "\(data.count)",
                "Access-Control-Allow-Origin": "*",
                "Accept-Ranges": "bytes"
            ]
            if let contentRange = httpResponse.value(forHTTPHeaderField: "Content-Range") {
                responseHeaders["Content-Range"] = contentRange
            }
            
            sendHTTPResponse(
                status: httpResponse.statusCode,
                statusText: httpResponse.statusCode == 206 ? "Partial Content" : "OK",
                headers: responseHeaders,
                body: data,
                to: connection
            )
        } catch {
            sendHTTPResponse(status: 500, statusText: "Internal Error", headers: [:], body: Data(error.localizedDescription.utf8), to: connection)
        }
    }
    
    // MARK: - 无 SNI TLS 直连客户端 (绕过异常 CDN 强制重置)
    
    private struct DirectTLSResponse {
        let statusCode: Int
        let headers: [String: String]
        let data: Data
    }
    
    /// 使用 NWConnection 直接连接目标 IP 443 端口，显式禁用 SNI 扩展并跳过自签名证书校验
    private func fetchViaNoSNITLS(
        targetIP: String,
        hostHeader: String,
        targetURL: URL,
        clientHeaders: [String: String]
    ) async throws -> DirectTLSResponse {
        return try await withCheckedThrowingContinuation { continuation in
            let tlsOptions = NWProtocolTLS.Options()
            let secOptions = tlsOptions.securityProtocolOptions
            
            // 关键点：禁用 SNI，防止华为云 CDN 因为找不到 tp*.zdmhyg.cn 的证书而主动发送 RST
            sec_protocol_options_set_tls_server_name(secOptions, nil)
            
            // 允许无证书/自签名证书通过（仅限该代理连接）
            sec_protocol_options_set_verify_block(secOptions, { _, _, completion in
                completion(true)
            }, queue)
            
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.noDelay = true
            let params = NWParameters(tls: tlsOptions, tcp: tcpOptions)
            
            guard let port = NWEndpoint.Port(rawValue: UInt16(targetURL.port ?? 443)) else {
                continuation.resume(throwing: NSError(domain: "LocalPlaybackProxy", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid Port"]))
                return
            }
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(targetIP), port: port)
            let conn = NWConnection(to: endpoint, using: params)
            
            var hasResumed = false
            let resumeOnce: (Result<DirectTLSResponse, Error>) -> Void = { result in
                guard !hasResumed else { return }
                hasResumed = true
                conn.cancel()
                switch result {
                case .success(let res): continuation.resume(returning: res)
                case .failure(let err): continuation.resume(throwing: err)
                }
            }
            
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    // 构造 HTTP/1.1 请求报文
                    var path = targetURL.path
                    if path.isEmpty { path = "/" }
                    if let query = targetURL.query, !query.isEmpty {
                        path += "?\(query)"
                    }
                    
                    var lines = [
                        "GET \(path) HTTP/1.1",
                        "Host: \(hostHeader)",
                        "User-Agent: Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15",
                        "Referer: https://\(hostHeader)/",
                        "Connection: close"
                    ]
                    if let range = clientHeaders["range"] {
                        lines.append("Range: \(range)")
                    }
                    lines.append("\r\n")
                    
                    let reqData = Data(lines.joined(separator: "\r\n").utf8)
                    conn.send(content: reqData, completion: .contentProcessed { sendErr in
                        if let sendErr = sendErr {
                            resumeOnce(.failure(sendErr))
                            return
                        }
                        self.readAllData(from: conn, accumulated: Data(), completion: resumeOnce)
                    })
                case .failed(let err):
                    resumeOnce(.failure(err))
                case .cancelled:
                    resumeOnce(.failure(NSError(domain: "LocalPlaybackProxy", code: -999, userInfo: [NSLocalizedDescriptionKey: "Connection Cancelled"])))
                default:
                    break
                }
            }
            
            conn.start(queue: self.queue)
        }
    }
    
    /// 递归读取 NWConnection 直至 EOF 并解析 HTTP 报文
    private func readAllData(
        from connection: NWConnection,
        accumulated: Data,
        completion: @escaping (Result<DirectTLSResponse, Error>) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { content, _, isComplete, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            
            var buffer = accumulated
            if let content = content {
                buffer.append(content)
            }
            
            if isComplete || (content == nil && error == nil) {
                // 解析 HTTP 头部与 Body
                if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    let headerData = buffer.subdata(in: 0..<headerEnd.lowerBound)
                    let bodyData = buffer.subdata(in: headerEnd.upperBound..<buffer.count)
                    
                    let headerString = String(data: headerData, encoding: .utf8) ?? ""
                    let lines = headerString.components(separatedBy: "\r\n")
                    var statusCode = 200
                    if let statusLine = lines.first {
                        let parts = statusLine.components(separatedBy: " ")
                        if parts.count >= 2, let code = Int(parts[1]) {
                            statusCode = code
                        }
                    }
                    
                    var headers: [String: String] = [:]
                    for line in lines.dropFirst() {
                        if let colon = line.firstIndex(of: ":") {
                            let k = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                            let v = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                            headers[k] = v
                        }
                    }
                    headers["Content-Length"] = "\(bodyData.count)"
                    headers["Access-Control-Allow-Origin"] = "*"
                    headers["Accept-Ranges"] = "bytes"
                    
                    completion(.success(DirectTLSResponse(statusCode: statusCode, headers: headers, data: bodyData)))
                } else {
                    completion(.success(DirectTLSResponse(statusCode: 200, headers: ["Content-Length": "\(buffer.count)"], data: buffer)))
                }
                return
            }
            
            self.readAllData(from: connection, accumulated: buffer, completion: completion)
        }
    }
    
    // MARK: - DNS 解析与智能兜底
    
    /// 判断域名是否属于 TLS 证书损坏/被重置黑名单
    private func isHostMatchingBrokenTLSPatterns(_ host: String) -> Bool {
        for pattern in Self.brokenTLSHostPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(host.startIndex..<host.endIndex, in: host)
                if regex.firstMatch(in: host, options: [], range: range) != nil {
                    return true
                }
            }
        }
        return false
    }
    
    /// 解析域名真实 IPv4 地址（系统 DNS -> 阿里公共 DoH -> 静态保底）
    private func resolveIP(for host: String) async -> String? {
        cacheLock.lock()
        if let cached = ipCache[host], cached.expire > Date() {
            cacheLock.unlock()
            return cached.ip
        }
        cacheLock.unlock()
        
        // 1. 尝试系统原生 DNS (getaddrinfo)
        if let sysIP = resolveWithGetAddrInfo(host: host) {
            // 过滤回环地址与虚拟 fake-ip (198.18.x.x)
            if !sysIP.hasPrefix("127.") && !sysIP.hasPrefix("198.18.") {
                cacheResolvedIP(host: host, ip: sysIP)
                return sysIP
            }
        }
        
        // 2. 尝试公共 DoH (阿里 DNS)
        if let dohIP = await resolveWithDoH(host: host) {
            cacheResolvedIP(host: host, ip: dohIP)
            return dohIP
        }
        
        // 3. 静态节点保底
        if let fallback = Self.staticFallbackIPs[host] {
            cacheResolvedIP(host: host, ip: fallback)
            return fallback
        }
        
        return nil
    }
    
    private func cacheResolvedIP(host: String, ip: String) {
        cacheLock.lock()
        ipCache[host] = (ip, Date().addingTimeInterval(3600))
        cacheLock.unlock()
    }
    
    private func resolveWithGetAddrInfo(host: String) -> String? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let res = res else {
            return nil
        }
        defer { freeaddrinfo(res) }
        
        var ptr: UnsafeMutablePointer<addrinfo>? = res
        while let current = ptr {
            if current.pointee.ai_family == AF_INET {
                var addr = current.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &addr.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                    return String(cString: buffer)
                }
            }
            ptr = current.pointee.ai_next
        }
        return nil
    }
    
    private func resolveWithDoH(host: String) async -> String? {
        guard let url = URL(string: "https://223.5.5.5/resolve?name=\(host)&type=1") else {
            return nil
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let answers = json["Answer"] as? [[String: Any]] {
                for ans in answers {
                    if let type = ans["type"] as? Int, type == 1,
                       let ip = ans["data"] as? String, !ip.isEmpty {
                        return ip
                    }
                }
            }
        } catch {}
        return nil
    }
    
    // MARK: - 响应发送
    
    private func sendHTTPResponse(
        status: Int,
        statusText: String,
        headers: [String: String],
        body: Data,
        to connection: NWConnection
    ) {
        var headerLines = ["HTTP/1.1 \(status) \(statusText)"]
        var finalHeaders = headers
        finalHeaders["Content-Length"] = "\(body.count)"
        finalHeaders["Connection"] = "close"
        if finalHeaders["Access-Control-Allow-Origin"] == nil {
            finalHeaders["Access-Control-Allow-Origin"] = "*"
        }
        
        for (k, v) in finalHeaders {
            headerLines.append("\(k): \(v)")
        }
        headerLines.append("\r\n")
        
        let headerData = Data(headerLines.joined(separator: "\r\n").utf8)
        var responseData = headerData
        responseData.append(body)
        
        connection.send(content: responseData, completion: .contentProcessed { [weak connection] _ in
            connection?.cancel()
        })
    }
}

// MARK: - SSL 信任校验跳过委托 (仅限内部代理 IP 直连会话)

private final class InsecureSSLSessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let serverTrust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
