import Foundation
import SwiftUI
import Combine

/// 首页缓存数据模型
struct CachedHomeData: Codable {
    let sourceKey: String
    let sorts: [MovieSort.SortData]
    let homeVideos: [Movie.Video]
    var categoryVideos: [String: [Movie.Video]]
    let timestamp: Date
}

/// 首页 ViewModel
@MainActor
class HomeViewModel: ObservableObject {
    /// 分类列表（包含手动注入的"推荐"分类）。
    @Published var sorts: [MovieSort.SortData] = []
    /// 当前选中的分类。
    @Published var selectedSort: MovieSort.SortData?
    /// 首页推荐内容（对应"推荐"分类）。
    @Published var homeVideos: [Movie.Video] = []
    /// 普通分类的视频列表（分页加载）。
    @Published var categoryVideos: [Movie.Video] = []
    /// 页面加载状态（分类加载与分页共用）。
    @Published var isLoading = false
    /// 当前分类的分页页码。
    @Published var currentPage = 1
    /// 是否还有下一页。
    @Published var hasMore = true
    /// 错误提示文案。
    @Published var errorMessage: String?
    
    /// 源数据访问服务。
    private let sourceService = SourceService.shared
    /// 标记上次加载是否因网络错误失败（用于网络恢复自动重试）。
    private var lastLoadFailedDueToNetwork = false
    private var networkRestoredCancellable: AnyCancellable?
    
    /// 当前已成功加载的源标识
    private var currentLoadedSourceKey: String = ""
    /// 当前源各分类视频的缓存映射
    private var cachedCategoryVideos: [String: [Movie.Video]] = [:]
    
    // MARK: - 静态多级缓存
    
    private static var inMemoryCache: [String: CachedHomeData] = [:]
    private static let cacheKeyPrefix = "tvbox_home_cache_v2_"
    
    /// 读取缓存（先内存后磁盘）
    static func loadCache(for sourceKey: String) -> CachedHomeData? {
        guard !sourceKey.isEmpty else { return nil }
        if let mem = inMemoryCache[sourceKey] {
            return mem
        }
        guard let data = UserDefaults.standard.data(forKey: "\(cacheKeyPrefix)\(sourceKey)") else {
            return nil
        }
        do {
            let cached = try JSONDecoder().decode(CachedHomeData.self, from: data)
            inMemoryCache[sourceKey] = cached
            return cached
        } catch {
            return nil
        }
    }
    
    /// 保存缓存（同步写入内存与磁盘）
    static func saveCache(_ cacheData: CachedHomeData) {
        guard !cacheData.sourceKey.isEmpty else { return }
        inMemoryCache[cacheData.sourceKey] = cacheData
        do {
            let data = try JSONEncoder().encode(cacheData)
            UserDefaults.standard.set(data, forKey: "\(cacheKeyPrefix)\(cacheData.sourceKey)")
        } catch {
            print("保存首页缓存失败: \(error)")
        }
    }
    
    /// 清除所有首页缓存
    static func clearAllCache() {
        inMemoryCache.removeAll()
        let keys = UserDefaults.standard.dictionaryRepresentation().keys
        for key in keys where key.hasPrefix(cacheKeyPrefix) {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
    
    init() {
        setupNetworkRestoredAutoRetry()
    }
    
    /// 按源加载（优先使用缓存，避免切 Tab 时反复清空和网络拉取）
    func loadForSource(key: String, force: Bool = false) async {
        let effectiveKey = key.isEmpty ? (ApiConfig.shared.homeSourceBean?.key ?? "") : key
        guard !effectiveKey.isEmpty else { return }
        
        // 如果当前 ViewModel 已经加载了该源的数据且非强制刷新，直接返回保留当前状态
        if !force && currentLoadedSourceKey == effectiveKey && !sorts.isEmpty {
            return
        }
        
        currentLoadedSourceKey = effectiveKey
        
        // 优先读取缓存
        if !force, let cached = Self.loadCache(for: effectiveKey) {
            self.sorts = cached.sorts
            self.homeVideos = cached.homeVideos
            self.cachedCategoryVideos = cached.categoryVideos
            if self.selectedSort == nil || !self.sorts.contains(where: { $0.id == self.selectedSort?.id }) {
                self.selectedSort = cached.sorts.first
            }
            if let currentSort = self.selectedSort, currentSort.id != "home" {
                self.categoryVideos = cached.categoryVideos[currentSort.id] ?? []
            }
            self.isLoading = false
            self.errorMessage = nil
            return
        }
        
        // 缓存未命中或强制刷新时，发起网络请求
        await refresh(force: true)
    }
    
    /// 加载分类列表
    func loadSorts() async {
        guard let source = ApiConfig.shared.homeSourceBean else { return }
        isLoading = true
        errorMessage = nil
        
        do {
            let result = try await sourceService.getSort(sourceBean: source)
            
            // 插入本地"推荐"分类，保持 UI 与 Android 版本习惯一致。
            var allSorts = [MovieSort.SortData.home()]
            allSorts.append(contentsOf: result.sorts)
            
            self.sorts = allSorts
            self.homeVideos = result.homeVideos
            self.errorMessage = result.homeError
            lastLoadFailedDueToNetwork = false
            
            if selectedSort == nil || !allSorts.contains(where: { $0.id == selectedSort?.id }) {
                selectedSort = allSorts.first
            }
            
            // Do not persist a transient failed recommendation response.
            if result.homeError == nil {
                Self.saveCache(
                    CachedHomeData(
                        sourceKey: source.key,
                        sorts: allSorts,
                        homeVideos: result.homeVideos,
                        categoryVideos: cachedCategoryVideos,
                        timestamp: Date()
                    )
                )
            }
        } catch {
            errorMessage = error.localizedDescription
            lastLoadFailedDueToNetwork = error.isNetworkConnectionError
        }
        
        isLoading = false
    }
    
    /// 网络恢复时，若上次因网络错误导致首页为空，自动重新加载。
    private func setupNetworkRestoredAutoRetry() {
        networkRestoredCancellable = NetworkMonitor.shared.networkRestoredPublisher
            .sink { [weak self] in
                guard let self else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.lastLoadFailedDueToNetwork || (self.sorts.isEmpty && self.homeVideos.isEmpty) else { return }
                    await self.refresh(force: true)
                }
            }
    }
    
    /// 选择分类
    func selectSort(_ sort: MovieSort.SortData) {
        selectedSort = sort
        errorMessage = nil
        currentPage = 1
        hasMore = true
        
        if sort.id == "home" {
            categoryVideos = []
            return
        }
        
        // 优先展示分类缓存
        if let cached = cachedCategoryVideos[sort.id], !cached.isEmpty {
            categoryVideos = cached
            return
        }
        
        categoryVideos = []
        Task {
            await loadCategoryVideos(page: 1, sort: sort)
        }
    }
    
    /// 加载分类视频列表
    private func loadCategoryVideos(page: Int, sort: MovieSort.SortData) async {
        guard sort.id != "home" else { return }
        guard let source = ApiConfig.shared.homeSourceBean else { return }
        // 防重复并发加载，避免分页错序。
        guard !isLoading else { return }
        
        isLoading = true
        defer { isLoading = false }
        
        do {
            let videos = try await sourceService.getList(sourceBean: source, sortData: sort, page: page)
            
            // 分类切换过程中，丢弃旧请求结果
            guard selectedSort?.id == sort.id else { return }
            
            if page == 1 {
                categoryVideos = videos
                cachedCategoryVideos[sort.id] = videos
                // 保存分类缓存
                Self.saveCache(
                    CachedHomeData(
                        sourceKey: source.key,
                        sorts: sorts,
                        homeVideos: homeVideos,
                        categoryVideos: cachedCategoryVideos,
                        timestamp: Date()
                    )
                )
            } else {
                categoryVideos.append(contentsOf: videos)
            }
            // 以"返回非空"作为是否继续分页的轻量判断。
            currentPage = page
            hasMore = !videos.isEmpty
        } catch {
            guard selectedSort?.id == sort.id else { return }
            errorMessage = error.localizedDescription
        }
    }
    
    /// 加载下一页
    func loadMore() async {
        guard let lastItem = categoryVideos.last else { return }
        await loadMoreIfNeeded(currentItem: lastItem)
    }
    
    /// 当最后一个元素出现时触发加载下一页
    func loadMoreIfNeeded(currentItem: Movie.Video) async {
        guard selectedSort?.id != "home" else { return }
        guard hasMore, !isLoading else { return }
        guard categoryVideos.last?.id == currentItem.id else { return }
        guard let sort = selectedSort else { return }
        
        let nextPage = currentPage + 1
        await loadCategoryVideos(page: nextPage, sort: sort)
    }
    
    /// 刷新
    func refresh(force: Bool = false) async {
        currentPage = 1
        hasMore = true
        categoryVideos = []
        errorMessage = nil
        if force {
            cachedCategoryVideos.removeAll()
        }
        
        let key = ApiConfig.shared.homeSourceBean?.key ?? ""
        currentLoadedSourceKey = key
        
        await loadSorts()
        
        guard let sort = selectedSort else { return }
        if sort.id == "home" { return }
        
        if let matchedSort = sorts.first(where: { $0.id == sort.id }) {
            selectedSort = matchedSort
            await loadCategoryVideos(page: 1, sort: matchedSort)
        } else if let firstCategory = sorts.first(where: { $0.id != "home" }) {
            selectedSort = firstCategory
            await loadCategoryVideos(page: 1, sort: firstCategory)
        }
    }
}
