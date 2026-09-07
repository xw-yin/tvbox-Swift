import Foundation

/// 针对纯 Java DEX/JAR 爬虫的外置 Bridge 桥接代理服务
class BridgeService {
    static let shared = BridgeService()
    
    private let network = NetworkManager.shared
    
    private init() {}
    
    /// 获取当前配置的 Bridge 服务地址 (如 http://192.168.1.100:9978)
    var bridgeUrl: String {
        let url = UserDefaults.standard.string(forKey: HawkConfig.SPIDER_BRIDGE_URL) ?? ""
        return url.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// 是否已配置并启用 Bridge 代理
    var isConfigured: Bool {
        return !bridgeUrl.isEmpty && bridgeUrl.isValidURL
    }
    
    /// 保存 Bridge 代理服务地址
    func setBridgeUrl(_ url: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: HawkConfig.SPIDER_BRIDGE_URL)
        } else {
            UserDefaults.standard.set(trimmed, forKey: HawkConfig.SPIDER_BRIDGE_URL)
        }
    }
    
    // MARK: - 转发请求到 Bridge 服务
    
    func getSort(source: SourceBean) async throws -> (sorts: [MovieSort.SortData], homeVideos: [Movie.Video]) {
        guard isConfigured else {
            throw SourceError.unsupportedType("未配置 Bridge 桥接服务，无法解析非 JS 的原生 JAR 爬虫")
        }
        
        let url = try buildBridgeURL(action: "home", source: source)
        let jsonStr = try await network.getString(from: url)
        
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
    
    func getList(source: SourceBean, sortData: MovieSort.SortData, page: Int, filters: [String: String]?) async throws -> [Movie.Video] {
        guard isConfigured else {
            throw SourceError.unsupportedType("未配置 Bridge 桥接服务")
        }
        
        var extra: [URLQueryItem] = [
            URLQueryItem(name: "tid", value: sortData.id),
            URLQueryItem(name: "pg", value: String(page))
        ]
        if let filters = filters, let d = try? JSONSerialization.data(withJSONObject: filters),
           let str = String(data: d, encoding: .utf8) {
            extra.append(URLQueryItem(name: "filter", value: str))
        }
        
        let url = try buildBridgeURL(action: "category", source: source, extraParams: extra)
        let jsonStr = try await network.getString(from: url)
        
        guard let data = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["list"] as? [[String: Any]] else {
            return []
        }
        
        return parseVideoItems(list, sourceKey: source.key)
    }
    
    func getDetail(source: SourceBean, vodId: String) async throws -> VodInfo? {
        guard isConfigured else {
            throw SourceError.unsupportedType("未配置 Bridge 桥接服务")
        }
        
        let extra = [URLQueryItem(name: "ids", value: vodId)]
        let url = try buildBridgeURL(action: "detail", source: source, extraParams: extra)
        let jsonStr = try await network.getString(from: url)
        
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
    
    func search(source: SourceBean, keyword: String, page: Int = 1) async throws -> [Movie.Video] {
        guard isConfigured else {
            throw SourceError.unsupportedType("未配置 Bridge 桥接服务")
        }
        
        let extra = [
            URLQueryItem(name: "wd", value: keyword),
            URLQueryItem(name: "pg", value: String(page))
        ]
        let url = try buildBridgeURL(action: "search", source: source, extraParams: extra)
        let jsonStr = try await network.getString(from: url)
        
        guard let data = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["list"] as? [[String: Any]] else {
            return []
        }
        
        return parseVideoItems(list, sourceKey: source.key)
    }
    
    // MARK: - 辅助构建
    
    private func buildBridgeURL(action: String, source: SourceBean, extraParams: [URLQueryItem] = []) throws -> String {
        var base = bridgeUrl
        if base.hasSuffix("/") { base.removeLast() }
        
        guard var components = URLComponents(string: "\(base)/proxy") else {
            throw SourceError.invalidApiUrl(bridgeUrl)
        }
        
        var items: [URLQueryItem] = [
            URLQueryItem(name: "do", value: action),
            URLQueryItem(name: "key", value: source.key),
            URLQueryItem(name: "api", value: source.api),
            URLQueryItem(name: "ext", value: source.ext ?? "")
        ]
        items.append(contentsOf: extraParams)
        components.queryItems = items
        
        guard let finalUrl = components.url else {
            throw SourceError.invalidApiUrl(bridgeUrl)
        }
        return finalUrl.absoluteString
    }
    
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
}
