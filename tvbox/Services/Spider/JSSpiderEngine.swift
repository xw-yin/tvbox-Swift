import Foundation
import JavaScriptCore
import CryptoKit

/// 基于 Apple 原生 JavaScriptCore 的 TVBox 动态爬虫（JS / Drpy）引擎
class JSSpiderEngine {
    static let shared = JSSpiderEngine()
    
    /// 脚本缓存（URL -> JS 源码）
    private var scriptCache: [String: String] = [:]
    private let cacheLock = NSLock()
    
    /// 执行 Spider 操作的专用并发串行队列，避免多线程同时读写单个 JSContext
    private let executionQueue = DispatchQueue(label: "com.tvbox.jsspider", qos: .userInitiated)
    
    private init() {}
    
    // MARK: - 判定是否为 JS 爬虫
    
    /// 检测源是否为 JS / Drpy 爬虫源
    static func isJsSpider(source: SourceBean) -> Bool {
        if source.type != 3 { return false }
        
        // 1. api 包含 .js
        if source.api.lowercased().hasSuffix(".js") || source.api.lowercased().contains(".js?") {
            return true
        }
        
        // 2. api 声明为 Drpy / CatVod JS 规则
        let lowerApi = source.api.lowercased()
        if lowerApi.contains("drpy") || lowerApi.contains("hipy") || lowerApi == "csp_drpy" {
            return true
        }
        
        // 3. ext 字段为 .js 地址或包含 JS 代码
        if let ext = source.ext?.trimmingCharacters(in: .whitespacesAndNewlines), !ext.isEmpty {
            let lowerExt = ext.lowercased()
            if lowerExt.hasSuffix(".js") || lowerExt.contains(".js?") {
                return true
            }
            if ext.contains("var rule") || ext.contains("function home") || ext.contains("rule =") {
                return true
            }
        }
        
        // 4. api 或 ext 声明为 XPTV 扩展规范
        if lowerApi.contains("xptv") || lowerApi.contains("xptv-extensions") {
            return true
        }
        if let ext = source.ext?.lowercased() {
            if ext.contains("xptv") || ext.contains("xptv-extensions") || ext.contains("getconfig") {
                return true
            }
        }
        
        return false
    }
    
    /// 获取 JS 脚本的下载地址或原始代码
    func resolveScriptTarget(source: SourceBean, baseConfigUrl: String) -> (url: String?, code: String?) {
        // 如果 ext 自身包含 JS 代码
        if let ext = source.ext, ext.contains("var rule") || ext.contains("function home") || ext.contains("getConfig") {
            return (nil, ext)
        }
        
        // 优先检查 ext 是否为独立 JS 脚本地址
        if let ext = source.ext?.trimmingCharacters(in: .whitespacesAndNewlines),
           ext.hasPrefix("http://") || ext.hasPrefix("https://"),
           ext.lowercased().contains(".js") {
            return (ext, nil)
        }
        
        // 检查 api 是否为完整 HTTP JS 地址
        if source.api.hasPrefix("http://") || source.api.hasPrefix("https://") {
            return (source.api, nil)
        }
        
        // 如果是相对路径（如 ./lib/drpy.js 或 lib/xxx.js）
        if source.api.lowercased().contains(".js"), !baseConfigUrl.isEmpty {
            if let resolved = resolveRelativeUrl(base: baseConfigUrl, path: source.api) {
                return (resolved, nil)
            }
        }
        
        // 检查 ext 是否为相对路径
        if let ext = source.ext, ext.lowercased().contains(".js"), !baseConfigUrl.isEmpty {
            if let resolved = resolveRelativeUrl(base: baseConfigUrl, path: ext) {
                return (resolved, nil)
            }
        }
        
        return (nil, nil)
    }
    
    // MARK: - 核心接口执行 (分类、列表、详情、搜索、播放)
    
    /// 获取分类与首页推荐
    func getSort(source: SourceBean, baseConfigUrl: String) async throws -> (sorts: [MovieSort.SortData], homeVideos: [Movie.Video]) {
        let jsonStr = try await executeSpider(source: source, baseConfigUrl: baseConfigUrl) { context in
            let fn = context.objectForKeyedSubscript("__spider_home" as NSString)
            let result = fn?.call(withArguments: [true])
            return result?.toString() ?? "{}"
        }
        
        guard let data = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ([], [])
        }
        
        var sorts: [MovieSort.SortData] = []
        if let classList = json["class"] as? [[String: Any]] {
            for item in classList {
                let id = String(describing: item["type_id"] ?? item["type_name"] ?? "")
                let name = String(describing: item["type_name"] ?? "")
                if !id.isEmpty && !name.isEmpty {
                    sorts.append(MovieSort.SortData(id: id, name: name))
                }
            }
        }
        
        var homeVideos: [Movie.Video] = []
        if let list = json["list"] as? [[String: Any]] {
            homeVideos = parseVideoItems(list, sourceKey: source.key)
        }
        
        return (sorts, homeVideos)
    }
    
    /// 分页获取分类视频列表
    func getList(source: SourceBean, sortData: MovieSort.SortData, page: Int, filters: [String: String]?, baseConfigUrl: String) async throws -> [Movie.Video] {
        let filterJson: String
        if let filters = filters, let data = try? JSONSerialization.data(withJSONObject: filters) {
            filterJson = String(data: data, encoding: .utf8) ?? "{}"
        } else {
            filterJson = "{}"
        }
        
        let jsonStr = try await executeSpider(source: source, baseConfigUrl: baseConfigUrl) { context in
            let fn = context.objectForKeyedSubscript("__spider_category" as NSString)
            let result = fn?.call(withArguments: [sortData.id, String(page), true, filterJson])
            return result?.toString() ?? "{}"
        }
        
        guard let data = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["list"] as? [[String: Any]] else {
            return []
        }
        
        return parseVideoItems(list, sourceKey: source.key)
    }
    
    /// 获取视频详情
    func getDetail(source: SourceBean, vodId: String, baseConfigUrl: String) async throws -> VodInfo? {
        let jsonStr = try await executeSpider(source: source, baseConfigUrl: baseConfigUrl) { context in
            let fn = context.objectForKeyedSubscript("__spider_detail" as NSString)
            let result = fn?.call(withArguments: [vodId])
            return result?.toString() ?? "{}"
        }
        
        guard let data = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["list"] as? [[String: Any]],
              let first = list.first else {
            return nil
        }
        
        var video = Movie.Video(id: vodId)
        video.name = String(describing: first["vod_name"] ?? "")
        video.pic = String(describing: first["vod_pic"] ?? "")
        video.note = String(describing: first["vod_remarks"] ?? first["vod_note"] ?? "")
        video.year = String(describing: first["vod_year"] ?? "")
        video.area = String(describing: first["vod_area"] ?? "")
        video.type = String(describing: first["vod_type"] ?? first["type_name"] ?? "")
        video.director = String(describing: first["vod_director"] ?? "")
        video.actor = String(describing: first["vod_actor"] ?? "")
        video.des = String(describing: first["vod_content"] ?? "")
        video.sourceKey = source.key
        
        let playFrom = String(describing: first["vod_play_from"] ?? "默认")
        let playUrl = String(describing: first["vod_play_url"] ?? "")
        
        return VodInfo.from(video: video, playFrom: playFrom, playUrl: playUrl)
    }
    
    /// 搜索视频
    func search(source: SourceBean, keyword: String, quick: Bool = false, page: Int = 1, baseConfigUrl: String) async throws -> [Movie.Video] {
        let jsonStr = try await executeSpider(source: source, baseConfigUrl: baseConfigUrl) { context in
            let fn = context.objectForKeyedSubscript("__spider_search" as NSString)
            let result = fn?.call(withArguments: [keyword, quick, String(page)])
            return result?.toString() ?? "{}"
        }
        
        guard let data = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["list"] as? [[String: Any]] else {
            return []
        }
        
        return parseVideoItems(list, sourceKey: source.key)
    }
    
    /// 解析视频播放真实地址（调用 Spider play 接口）
    func getPlayUrl(source: SourceBean, flag: String, url: String, baseConfigUrl: String) async throws -> (url: String, headers: [String: String]?) {
        let jsonStr = try await executeSpider(source: source, baseConfigUrl: baseConfigUrl) { context in
            let fn = context.objectForKeyedSubscript("__spider_play" as NSString)
            let result = fn?.call(withArguments: [flag, url, "[]"])
            return result?.toString() ?? "{}"
        }
        
        guard let data = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (url, nil)
        }
        
        let playUrl = json["url"] as? String ?? url
        let header = json["header"] as? [String: String]
        return (playUrl, header)
    }
    
    // MARK: - 底层 JSContext 构建与执行调度
    
    private func executeSpider<T>(
        source: SourceBean,
        baseConfigUrl: String,
        action: @escaping (JSContext) throws -> T
    ) async throws -> T {
        // 1. 获取脚本代码并转换为适合在 JSContext 同步执行的语法
        let rawScript = try await loadScript(source: source, baseConfigUrl: baseConfigUrl)
        let script = transformAsyncToSync(rawScript)
        
        // 2. 在非主线程串行队列执行 JSContext，避免阻塞 Swift Concurrency 协作线程池
        return try await withCheckedThrowingContinuation { continuation in
            executionQueue.async {
                do {
                    let context = self.createContext()
                    
                    // 注入基础环境
                    context.evaluateScript(DrpyRuntime.coreJS)
                    
                    // 执行爬虫代码
                    context.evaluateScript(script)
                    
                    // 注入执行包装器
                    context.evaluateScript(DrpyRuntime.runnerJS)
                    
                    // 初始化爬虫
                    let extParam = source.ext ?? ""
                    let initFn = context.objectForKeyedSubscript("__spider_init" as NSString)
                    _ = initFn?.call(withArguments: [extParam])
                    
                    let result = try action(context)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    private func loadScript(source: SourceBean, baseConfigUrl: String) async throws -> String {
        let target = resolveScriptTarget(source: source, baseConfigUrl: baseConfigUrl)
        
        if let code = target.code, !code.isEmpty {
            return code
        }
        
        guard let url = target.url, !url.isEmpty else {
            throw SourceError.parseError("无法解析该源的 JS 脚本地址: \(source.name)")
        }
        
        cacheLock.lock()
        if let cached = scriptCache[url] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()
        
        let fetched = try await NetworkManager.shared.getString(from: url)
        guard !fetched.isEmpty else {
            throw SourceError.parseError("下载 JS 脚本失败: \(url)")
        }
        
        cacheLock.lock()
        scriptCache[url] = fetched
        cacheLock.unlock()
        
        return fetched
    }
    
    // MARK: - JSContext 实例初始化与 Bridge 注入
    
    private func createContext() -> JSContext {
        guard let context = JSContext() ?? JSContext(virtualMachine: JSVirtualMachine()) else {
            fatalError("Failed to create JSContext")
        }
        
        // 异常处理
        context.exceptionHandler = { _, exception in
            let errMsg = exception?.toString() ?? "未知 JS 错误"
            print("⚠️ [JSSpider Engine] JS Exception: \(errMsg)")
        }
        
        // 1. 日志重定向
        let logBlock: @convention(block) (String) -> Void = { msg in
            #if DEBUG
            print("[JSSpider Console] \(msg)")
            #endif
        }
        context.setObject(logBlock, forKeyedSubscript: "__native_log" as NSString)
        
        // 2. MD5
        let md5Block: @convention(block) (String) -> String = { text in
            let digest = Insecure.MD5.hash(data: Data(text.utf8))
            return digest.map { String(format: "%02hhx", $0) }.joined()
        }
        context.setObject(md5Block, forKeyedSubscript: "__native_md5" as NSString)
        
        // 3. Base64
        let b64EncodeBlock: @convention(block) (String) -> String = { text in
            Data(text.utf8).base64EncodedString()
        }
        let b64DecodeBlock: @convention(block) (String) -> String = { text in
            guard let data = Data(base64Encoded: text),
                  let str = String(data: data, encoding: .utf8) else {
                return ""
            }
            return str
        }
        context.setObject(b64EncodeBlock, forKeyedSubscript: "__native_base64_encode" as NSString)
        context.setObject(b64DecodeBlock, forKeyedSubscript: "__native_base64_decode" as NSString)
        
        // 4. 同步网络请求桥接
        let reqBlock: @convention(block) (String, String) -> String = { [weak self] urlStr, optJson in
            self?.performSynchronousRequest(urlStr: urlStr, optJson: optJson) ?? "{ \"content\": \"\", \"code\": 500 }"
        }
        context.setObject(reqBlock, forKeyedSubscript: "__native_request" as NSString)
        
        return context
    }
    
    /// 执行同步网络请求，服务于 JS 中的同步调用 (如 var html = req(url))
    private func performSynchronousRequest(urlStr: String, optJson: String) -> String {
        guard let url = URL(string: urlStr.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return "{ \"content\": \"\", \"code\": 400 }"
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        
        // 默认 Mobile User-Agent 提升站点兼容性
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        
        if let optData = optJson.data(using: .utf8),
           let opt = try? JSONSerialization.jsonObject(with: optData) as? [String: Any] {
            if let method = opt["method"] as? String {
                request.httpMethod = method.uppercased()
            }
            if let headers = opt["headers"] as? [String: String] {
                for (k, v) in headers {
                    request.setValue(v, forHTTPHeaderField: k)
                }
            }
            if let body = opt["body"] as? String {
                request.httpBody = body.data(using: .utf8)
            } else if let dataObj = opt["data"] {
                if let str = dataObj as? String {
                    request.httpBody = str.data(using: .utf8)
                } else if let dict = dataObj as? [String: Any],
                          let d = try? JSONSerialization.data(withJSONObject: dict) {
                    request.httpBody = d
                }
            }
        }
        
        var responseContent = ""
        var statusCode = 200
        var responseHeaders: [String: String] = [:]
        
        let semaphore = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse {
                statusCode = http.statusCode
                for (k, v) in http.allHeaderFields {
                    responseHeaders[String(describing: k)] = String(describing: v)
                }
            }
            if let data = data {
                // 自动尝试 UTF-8 或 GBK 解码
                if let str = String(data: data, encoding: .utf8) {
                    responseContent = str
                } else {
                    let gbkEncoding = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
                    responseContent = String(data: data, encoding: String.Encoding(rawValue: gbkEncoding)) ?? ""
                }
            }
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 15)
        
        let resDict: [String: Any] = [
            "code": statusCode,
            "content": responseContent,
            "headers": responseHeaders
        ]
        
        if let resData = try? JSONSerialization.data(withJSONObject: resDict),
           let resStr = String(data: resData, encoding: .utf8) {
            return resStr
        }
        return "{ \"content\": \"\", \"code\": 200 }"
    }
    
    // MARK: - 辅助映射
    
    private func parseVideoItems(_ list: [[String: Any]], sourceKey: String) -> [Movie.Video] {
        var result: [Movie.Video] = []
        for item in list {
            let id = String(describing: item["vod_id"] ?? item["id"] ?? "")
            guard !id.isEmpty else { continue }
            
            var video = Movie.Video(id: id)
            video.name = String(describing: item["vod_name"] ?? item["name"] ?? item["title"] ?? "")
            video.pic = String(describing: item["vod_pic"] ?? item["pic"] ?? item["img"] ?? "")
            video.note = String(describing: item["vod_remarks"] ?? item["note"] ?? item["remarks"] ?? "")
            video.year = String(describing: item["vod_year"] ?? item["year"] ?? "")
            video.sourceKey = sourceKey
            result.append(video)
        }
        return result
    }
    
    private func resolveRelativeUrl(base: String, path: String) -> String? {
        guard let baseUrl = URL(string: base) else { return nil }
        return URL(string: path, relativeTo: baseUrl)?.absoluteString
    }
    
    /// 将爬虫脚本中的 async/await 关键字平坦化为同步执行，确保在 JSContext 串行线程中能够被同步求值并返回
    private func transformAsyncToSync(_ code: String) -> String {
        guard code.contains("async") || code.contains("await") else {
            return code
        }
        var result = code
        result = result.replacingOccurrences(
            of: #"\basync\s+function\b"#,
            with: "function",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"\basync\s*\("#,
            with: "(",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"\bawait\s+"#,
            with: "",
            options: .regularExpression
        )
        return result
    }
}
