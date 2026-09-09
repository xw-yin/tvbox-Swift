import Foundation

/// XPTV 预设扩展数据管理器
/// 提供内置 72 款精选 XPTV 页面/站点的读取、检索与导入支持
enum XptvPresetSources {
    private static var cachedSources: [SourceBean]?
    
    /// 加载内置的 XPTV 扩展源列表
    static func loadPresetSources() -> [SourceBean] {
        if let cached = cachedSources, !cached.isEmpty {
            return cached
        }
        
        var jsonData: Data?
        
        // 1. 尝试从应用 Bundle 中读取
        if let url = Bundle.main.url(forResource: "xptv_sources", withExtension: "json") {
            jsonData = try? Data(contentsOf: url)
        }
        
        // 2. 备用尝试从当前工程资源目录查找
        if jsonData == nil {
            let possiblePaths = [
                Bundle.main.bundlePath + "/xptv_sources.json",
                Bundle.main.resourcePath.map { $0 + "/xptv_sources.json" } ?? ""
            ]
            for path in possiblePaths where !path.isEmpty {
                if let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                    jsonData = data
                    break
                }
            }
        }
        
        guard let data = jsonData else {
            print("[XptvPresetSources] 未能找到 xptv_sources.json 资源")
            return []
        }
        
        do {
            let decoded = try JSONDecoder().decode(AppConfigData.self, from: data)
            let sites = decoded.sites ?? []
            let sources = sites.map { site in
                SourceBean(
                    key: site.key ?? "xptv_\(UUID().uuidString)",
                    name: site.name ?? "未知扩展",
                    api: site.api ?? "",
                    searchable: site.searchable?.value ?? 1,
                    filterable: site.filterable?.value ?? 1,
                    quickSearch: site.quickSearch?.value ?? 1,
                    playerType: site.playerType?.value ?? 0,
                    type: 3,
                    ext: site.ext?.stringValue ?? site.api
                )
            }
            cachedSources = sources
            return sources
        } catch {
            print("[XptvPresetSources] 解析 xptv_sources.json 失败: \(error)")
            return []
        }
    }
}
