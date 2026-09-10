import Foundation
import JavaScriptCore
import CryptoKit
import Security

/// 基于 Apple 原生 JavaScriptCore 的 TVBox 动态爬虫（JS / Drpy）引擎
class JSSpiderEngine {
    static let shared = JSSpiderEngine()
    
    /// 脚本缓存（URL -> JS 源码）
    private var scriptCache: [String: String] = [:]
    private let cacheLock = NSLock()
    // Accessed only on executionQueue; preserve script state and $cache between pages.
    private var contexts: [String: (script: String, context: JSContext)] = [:]
    
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
        
        return false
    }
    
    /// 获取 JS 脚本的下载地址或原始代码
    func resolveScriptTarget(source: SourceBean, baseConfigUrl: String) -> (url: String?, code: String?) {
        // 如果 ext 自身包含 JS 代码
        if let ext = source.ext, ext.contains("var rule") || ext.contains("function home") || ext.contains("rule =") {
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
    func getSort(source: SourceBean, baseConfigUrl: String) async throws -> (sorts: [MovieSort.SortData], homeVideos: [Movie.Video], homeError: String?) {
        let jsonStr = try await executeSpider(source: source, baseConfigUrl: baseConfigUrl) { context in
            return try self.callSpider(context, function: "__spider_home", arguments: [true])
        }
        
        guard let data = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SourceError.parseError("分类接口未返回 JSON 对象")
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
        
        return (sorts, homeVideos, json["homeError"] as? String)
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
            return try self.callSpider(context, function: "__spider_category", arguments: [sortData.id, String(page), true, filterJson])
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
            return try self.callSpider(context, function: "__spider_detail", arguments: [vodId])
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
            return try self.callSpider(context, function: "__spider_search", arguments: [keyword, quick, String(page)])
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
            return try self.callSpider(context, function: "__spider_play", arguments: [flag, url, "[]"])
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
        // 保留原脚本的 async/await、Promise 和字符串内容。
        let rawScript = try await loadScript(source: source, baseConfigUrl: baseConfigUrl)
        let script = rawScript
        
        // 2. 在非主线程串行队列执行 JSContext，避免阻塞 Swift Concurrency 协作线程池
        return try await withCheckedThrowingContinuation { continuation in
            executionQueue.async {
                do {
                    let key = [source.key, baseConfigUrl, source.api, source.ext ?? ""].joined(separator: "\n")
                    let context: JSContext
                    if let cached = self.contexts[key], cached.script == script {
                        context = cached.context
                        context.exception = nil
                    } else {
                        context = self.createContext()
                        guard let domURL = Bundle.main.url(forResource: "SpiderDOM", withExtension: "js") else {
                            throw SourceError.parseError("缺少 SpiderDOM.js 解析资源")
                        }
                        try self.evaluate(try String(contentsOf: domURL, encoding: .utf8), in: context, stage: "加载运行库")
                        try self.evaluate(DrpyRuntime.coreJS, in: context, stage: "加载基础环境")
                        let extParam = source.ext ?? ""
                        let configData = extParam.data(using: .utf8) ?? Data()
                        let configObject = (try? JSONSerialization.jsonObject(with: configData)) as? [String: Any]
                        context.setObject(configObject == nil ? "{}" : extParam, forKeyedSubscript: "$config_str" as NSString)
                        try self.evaluate(script, in: context, stage: "加载源脚本")
                        try self.evaluate(DrpyRuntime.runnerJS, in: context, stage: "加载接口桥接")
                        _ = try self.callSpider(context, function: "__spider_init", arguments: [extParam])
                        if self.contexts.count >= 8, let evicted = self.contexts.keys.first {
                            self.contexts.removeValue(forKey: evicted)
                        }
                        self.contexts[key] = (script, context)
                    }

                    let result = try action(context)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: SourceError.parseError("\(source.name)：\(error.localizedDescription)"))
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
        context.exceptionHandler = { context, exception in
            context?.exception = exception
            let errMsg = exception?.toString() ?? "未知 JS 错误"
            print("⚠️ [JSSpider Engine] JS Exception: \(errMsg)")
        }

        // CryptoJS needs secure random bytes for salts/IVs in JavaScriptCore.
        let randomBlock: @convention(block) (Int) -> String = { count in
            guard count >= 0, count <= 65536 else { return "" }
            var bytes = [UInt8](repeating: 0, count: count)
            guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess,
                  let data = try? JSONSerialization.data(withJSONObject: bytes),
                  let json = String(data: data, encoding: .utf8) else { return "" }
            return json
        }
        context.setObject(randomBlock, forKeyedSubscript: "__native_random_bytes" as NSString)
        context.evaluateScript("""
        var crypto = { getRandomValues: function(array) {
            var bytes = JSON.parse(__native_random_bytes(array.byteLength));
            new Uint8Array(array.buffer, array.byteOffset, array.byteLength).set(bytes);
            return array;
        }};
        """)
        
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
            if let timeout = opt["timeout"] as? Double, timeout > 0 {
                request.timeoutInterval = min(timeout / 1000, 60)
            }
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
                    if request.value(forHTTPHeaderField: "Content-Type") == nil {
                        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    }
                }
            }
        }
        
        var responseContent = ""
        var statusCode = 0
        var responseHeaders: [String: String] = [:]
        var responseError: String?
        let responseLock = NSLock()
        
        let semaphore = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            responseLock.lock()
            defer {
                responseLock.unlock()
                semaphore.signal()
            }
            responseError = error?.localizedDescription
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
        }
        task.resume()
        let timedOut = semaphore.wait(timeout: .now() + request.timeoutInterval + 1) == .timedOut
        if timedOut { task.cancel() }
        responseLock.lock()
        defer { responseLock.unlock() }
        
        var resDict: [String: Any] = [
            "code": statusCode,
            "content": responseContent,
            "headers": responseHeaders
        ]
        if timedOut {
            resDict["error"] = "请求超时"
        } else if let responseError = responseError {
            resDict["error"] = responseError
        }
        
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
    
    private func evaluate(_ script: String, in context: JSContext, stage: String) throws {
        context.exception = nil
        context.evaluateScript(script)
        if let exception = context.exception {
            throw SourceError.parseError("\(stage)：\(exception.toString() ?? "未知 JS 错误")")
        }
    }

    /// The wrapper settles real Promises before their JSON value is read.
    private func callSpider(_ context: JSContext, function: String, arguments: [Any]) throws -> String {
        context.setObject(function, forKeyedSubscript: "__spider_method" as NSString)
        context.setObject(arguments, forKeyedSubscript: "__spider_arguments" as NSString)
        try evaluate(DrpyRuntime.callJS, in: context, stage: function)
        let deadline = Date().addingTimeInterval(30)
        while context.objectForKeyedSubscript("__spider_completion")?.forProperty("done")?.toBool() != true {
            guard Date() < deadline else {
                throw SourceError.parseError("\(function)：等待异步脚本超时")
            }
            // JavaScriptCore drains Promise jobs at API boundaries. Run-loop work
            // also permits native callbacks without blocking the main thread.
            RunLoop.current.run(until: Date().addingTimeInterval(0.001))
            try evaluate("void 0", in: context, stage: function)
        }
        guard let completion = context.objectForKeyedSubscript("__spider_completion") else {
            throw SourceError.parseError("\(function)：未返回执行结果")
        }
        if let error = completion.forProperty("error"), !error.isUndefined, !error.isNull {
            throw SourceError.parseError("\(function)：\(error.toString() ?? "未知 JS 错误")")
        }
        guard let value = completion.forProperty("value"), value.isString,
              let json = value.toString() else {
            throw SourceError.parseError("\(function)：脚本未返回 JSON 数据")
        }
        return json
    }
}
