import Foundation
import SwiftUI

struct PlaybackQualityOption: Identifiable, Hashable {
    /// “自动”选项固定标识。
    static let autoIdentifier = "auto"
    /// 选项唯一标识（这里直接使用播放地址或固定 auto id）。
    let id: String
    /// UI 展示名（如 1080p / 720p / 自动）。
    let name: String
    /// 对应播放地址。
    let url: String
    
    var isAuto: Bool {
        id == Self.autoIdentifier
    }
    
    static func auto(url: String) -> PlaybackQualityOption {
        PlaybackQualityOption(id: autoIdentifier, name: "自动", url: url)
    }
}

/// 详情页 ViewModel
@MainActor
class DetailViewModel: ObservableObject {
    /// 详情信息主体。
    @Published var vodInfo: VodInfo?
    /// 加载状态。
    @Published var isLoading = false
    /// 错误提示。
    @Published var errorMessage: String?
    /// 当前选中线路。
    @Published var selectedFlag: String = ""
    /// 当前选中剧集索引。
    @Published var selectedEpisodeIndex: Int = 0
    /// 是否处于播放态。
    @Published var isPlaying = false
    /// 当前实际播放地址（可能是原始地址，也可能是清晰度切换后的子流地址）。
    @Published var playUrl: String?
    /// 本次播放命中的解析接口名称（直链/解析失败时为 nil）。
    @Published var activeParseName: String?
    /// 各线路测速状态（key 为线路 flag）。
    @Published var flagSpeeds: [String: FlagSpeedState] = [:]
    /// 续播起始位置（秒）。
    @Published var resumeSeconds: Double = 0
    /// 当前可选清晰度列表。
    @Published var qualityOptions: [PlaybackQualityOption] = []
    /// 当前选中的清晰度 id。
    @Published var selectedQualityId: String = PlaybackQualityOption.autoIdentifier
    /// 播放器高频回调进度，不直接绑定 UI，避免高频刷新引发性能问题。
    private var realtimeProgressSeconds: Double = 0
    
    /// 数据服务与网络服务。
    private let sourceService = SourceService.shared
    private let network = NetworkManager.shared
    /// 当前清晰度列表对应的基础剧集地址。
    private var qualityBaseEpisodeURL: String = ""
    /// 清晰度解析缓存，key 为原始剧集 URL。
    private var qualityOptionCache: [String: [PlaybackQualityOption]] = [:]
    /// 清晰度解析任务，用于取消旧请求。
    private var qualityResolveTask: Task<Void, Never>?
    /// 解析令牌，防止异步结果回写到过期状态。
    private var qualityResolveToken = UUID()
    /// 线路测速任务（切换影片时取消，避免旧结果回写）。
    private var speedTestTask: Task<Void, Never>?
    
    /// 加载视频详情
    func loadDetail(video: Movie.Video) async {
        guard let source = ApiConfig.shared.getSource(key: video.sourceKey)
                ?? ApiConfig.shared.homeSourceBean else { return }
        
        isLoading = true
        errorMessage = nil
        
        do {
            if let info = try await sourceService.getDetail(sourceBean: source, vodId: video.id) {
                self.vodInfo = info
                self.selectedFlag = info.playFlag
                self.selectedEpisodeIndex = info.playIndex
                self.resumeSeconds = 0
                self.realtimeProgressSeconds = 0
                if let episode = info.currentEpisode {
                    updateQualityOptions(for: episode.url, resetSelection: true)
                } else {
                    resetQualityState()
                }
                self.testFlagSpeeds()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        
        isLoading = false
    }
    
    // MARK: - 线路测速

    /// 线路测速状态。
    enum FlagSpeedState: Equatable {
        /// 测速中。
        case testing
        /// 测速成功，毫秒。
        case success(ms: Int)
        /// 超时或失败。
        case failed
    }

    /// 对各线路首集地址做连通性测速（HEAD 优先，失败回退 Range GET）。
    /// 非直链地址跳过（需走解析链路，测速无意义）。
    func testFlagSpeeds() {
        speedTestTask?.cancel()
        guard let info = vodInfo, info.playFlags.count > 1 else {
            flagSpeeds = [:]
            return
        }
        flagSpeeds = Dictionary(uniqueKeysWithValues: info.playFlags.map { ($0, FlagSpeedState.testing) })
        // 探测内部全是 suspend 点（URLSession），不会阻塞主线程。
        speedTestTask = Task {
            let results = await withTaskGroup(of: (String, FlagSpeedState).self) { group in
                for flag in info.playFlags {
                    group.addTask {
                        let state = await Self.probeFlagSpeed(info: info, flag: flag)
                        return (flag, state)
                    }
                }
                var dict: [String: FlagSpeedState] = [:]
                for await (flag, state) in group {
                    dict[flag] = state
                }
                return dict
            }
            guard !Task.isCancelled else { return }
            self.flagSpeeds = results
        }
    }

    /// 探测单线路延迟。返回 testing 表示该线路无可测地址（UI 可忽略）。
    private static func probeFlagSpeed(info: VodInfo, flag: String) async -> FlagSpeedState {
        guard let urlString = info.playUrlMap[flag]?.first?.url,
              !urlString.isEmpty,
              ParseChainService.isDirectlyPlayable(urlString),
              let url = URL(string: urlString) else {
            return .failed
        }
        // 先 HEAD，失败再用 Range GET 兜底（部分站点不支持 HEAD）。
        if let ms = await probe(url: url, method: "HEAD", range: nil) {
            return .success(ms: ms)
        }
        if let ms = await probe(url: url, method: "GET", range: "bytes=0-1") {
            return .success(ms: ms)
        }
        return .failed
    }

    private static func probe(url: URL, method: String, range: String?) async -> Int? {
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = method
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        let start = Date()
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) else {
                return nil
            }
            return max(1, Int(Date().timeIntervalSince(start) * 1000))
        } catch {
            return nil
        }
    }

    /// 选择线路
    func selectFlag(_ flag: String) {
        guard selectedFlag != flag else { return }
        let currentIndex = selectedEpisodeIndex
        
        selectedFlag = flag
        vodInfo?.playFlag = flag
        resumeSeconds = 0
        realtimeProgressSeconds = 0
        
        let episodes = vodInfo?.playUrlMap[flag] ?? []
        guard !episodes.isEmpty else {
            selectedEpisodeIndex = 0
            vodInfo?.playIndex = 0
            resetQualityState()
            return
        }
        
        let targetIndex = min(max(currentIndex, 0), episodes.count - 1)
        selectedEpisodeIndex = targetIndex
        vodInfo?.playIndex = targetIndex
        let episodeURL = episodes[targetIndex].url
        updateQualityOptions(for: episodeURL, resetSelection: true)
        
        // 播放中切线路时，立即切换到新线路对应剧集
        if isPlaying {
            playEpisodeURL(episodeURL, resetQuality: true)
        }
    }
    
    /// 选择剧集并播放
    func selectEpisode(index: Int) {
        guard selectedEpisodeIndex != index || !isPlaying else { return }
        selectedEpisodeIndex = index
        vodInfo?.playIndex = index
        resumeSeconds = 0
        realtimeProgressSeconds = 0
        
        if let episode = vodInfo?.currentEpisode {
            // 仅当剧集 URL 变化时重置清晰度选择。
            let shouldResetQuality = qualityBaseEpisodeURL != episode.url
            playEpisodeURL(episode.url, resetQuality: shouldResetQuality)
        }
    }
    
    /// 应用历史续播状态并自动继续播放
    func applyPlaybackState(_ state: VodPlaybackState) {
        guard let info = vodInfo, !info.playFlags.isEmpty else { return }
        
        let fallbackFlag = info.playFlag.isEmpty ? info.playFlags[0] : info.playFlag
        let targetFlag = info.playFlags.contains(state.flag) ? state.flag : fallbackFlag
        
        selectedFlag = targetFlag
        vodInfo?.playFlag = targetFlag
        
        let episodes = vodInfo?.playUrlMap[targetFlag] ?? []
        guard !episodes.isEmpty else { return }
        
        let targetIndex = min(max(state.episodeIndex, 0), episodes.count - 1)
        selectedEpisodeIndex = targetIndex
        vodInfo?.playIndex = targetIndex
        
        let progress = max(0, state.progressSeconds)
        resumeSeconds = progress
        realtimeProgressSeconds = progress
        let episodeURL = episodes[targetIndex].url
        playEpisodeURL(episodeURL, resetQuality: true)
    }
    
    /// 触发剧集加载并播放（支持 Spider 爬虫真实流地址动态解析）
    private func playEpisodeURL(_ rawUrl: String, resetQuality: Bool = true) {
        guard let info = vodInfo else { return }
        let currentSource = ApiConfig.shared.getSource(key: info.sourceKey) ?? ApiConfig.shared.homeSourceBean
        let isSpider = currentSource?.type == 3
        let isExtJson = rawUrl.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{")
        
        if (isSpider || isExtJson), let source = currentSource {
            Task {
                do {
                    let (resolvedUrl, _) = try await sourceService.getPlayUrl(
                        sourceBean: source,
                        flag: selectedFlag,
                        episodeUrl: rawUrl
                    )
                    let baseTargetUrl = resolvedUrl.isEmpty ? rawUrl : resolvedUrl
                    let sanitizedUrl = await PlaybackStreamSanitizer.shared.preparePlayableURL(from: baseTargetUrl)
                    await MainActor.run {
                        guard self.vodInfo?.currentEpisode?.url == rawUrl else { return }
                        self.updateQualityOptions(for: sanitizedUrl, resetSelection: resetQuality)
                        self.playUrl = self.selectedPlayableURL(fallback: sanitizedUrl)
                        self.activeParseName = nil
                        self.isPlaying = true
                    }
                } catch {
                    let fallbackSanitized = await PlaybackStreamSanitizer.shared.preparePlayableURL(from: rawUrl)
                    await MainActor.run {
                        self.updateQualityOptions(for: fallbackSanitized, resetSelection: resetQuality)
                        self.playUrl = self.selectedPlayableURL(fallback: fallbackSanitized)
                        self.activeParseName = nil
                        self.isPlaying = true
                    }
                }
            }
        } else {
            Task {
                var sanitizedUrl = await PlaybackStreamSanitizer.shared.preparePlayableURL(from: rawUrl)
                // 非直链地址且配置了走解析接口时，尝试解析链路还原真实播放地址；
                // 解析失败则保持原有行为（直接播放原始地址）。
                var usedParseName: String? = nil
                if !ParseChainService.isDirectlyPlayable(sanitizedUrl),
                   !ApiConfig.shared.effectiveParseList.isEmpty,
                   let resolved = try? await ParseChainService.resolve(rawUrl),
                   !resolved.url.isEmpty {
                    sanitizedUrl = await PlaybackStreamSanitizer.shared.preparePlayableURL(from: resolved.url)
                    usedParseName = resolved.parseName
                }
                let finalURL = sanitizedUrl
                await MainActor.run {
                    self.updateQualityOptions(for: finalURL, resetSelection: resetQuality)
                    self.playUrl = self.selectedPlayableURL(fallback: finalURL)
                    self.activeParseName = usedParseName
                    self.isPlaying = true
                }
            }
        }
    }
    
    /// 选择清晰度
    func selectQuality(_ option: PlaybackQualityOption) {
        guard qualityOptions.contains(option) else { return }
        selectedQualityId = option.id
        guard isPlaying else { return }
        
        // “自动”使用基础剧集地址；其他选项使用对应变体地址。
        let targetURL = option.url.isEmpty ? qualityBaseEpisodeURL : option.url
        guard !targetURL.isEmpty, playUrl != targetURL else { return }
        
        let progress = max(currentPlaybackSeconds(), 0)
        resumeSeconds = progress
        realtimeProgressSeconds = progress
        playUrl = targetURL
    }
    
    /// 播放器时间回调
    func updatePlaybackProgress(seconds: Double) {
        guard seconds.isFinite else { return }
        realtimeProgressSeconds = max(seconds, 0)
    }
    
    /// 当前实时进度（不触发 UI 高频刷新）
    func currentPlaybackSeconds() -> Double {
        max(realtimeProgressSeconds, resumeSeconds)
    }
    
    /// 仅在必要时同步快照到可观察状态
    func commitPlaybackProgressSnapshot() {
        let snapshot = max(realtimeProgressSeconds, 0)
        if abs(snapshot - resumeSeconds) >= 1 {
            resumeSeconds = snapshot
        }
    }
    
    /// 播放下一集
    func playNext() -> Bool {
        guard let info = vodInfo else { return false }
        let episodes = info.currentEpisodes
        if selectedEpisodeIndex + 1 < episodes.count {
            selectEpisode(index: selectedEpisodeIndex + 1)
            return true
        }
        return false
    }
    
    /// 播放上一集
    func playPrevious() -> Bool {
        if selectedEpisodeIndex > 0 {
            selectEpisode(index: selectedEpisodeIndex - 1)
            return true
        }
        return false
    }
    
    /// 当前剧集列表
    var currentEpisodes: [VodInfo.Episode] {
        vodInfo?.playUrlMap[selectedFlag] ?? []
    }
    
    /// 可选线路列表
    var flags: [String] {
        vodInfo?.playFlags ?? []
    }
    
    /// 是否存在可选清晰度
    var hasQualityChoices: Bool {
        qualityOptions.count > 1
    }
    
    private func selectedPlayableURL(fallback: String) -> String {
        // 若当前清晰度存在有效 URL，则优先使用；否则回退剧集原始地址。
        let selected = qualityOptions.first(where: { $0.id == selectedQualityId })?.url
        if let selected, !selected.isEmpty {
            return selected
        }
        return fallback
    }
    
    /// 重置清晰度解析与选择状态。
    private func resetQualityState() {
        qualityResolveTask?.cancel()
        qualityResolveTask = nil
        qualityBaseEpisodeURL = ""
        qualityOptions = []
        selectedQualityId = PlaybackQualityOption.autoIdentifier
        qualityResolveToken = UUID()
    }
    
    private func updateQualityOptions(for episodeURL: String, resetSelection: Bool) {
        let trimmedEpisodeURL = episodeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEpisodeURL.isEmpty else {
            resetQualityState()
            return
        }
        
        // 切换剧集时先取消旧任务，避免异步回写错位。
        qualityResolveTask?.cancel()
        qualityResolveTask = nil
        
        let autoOption = PlaybackQualityOption.auto(url: trimmedEpisodeURL)
        let previousSelected = selectedQualityId
        
        qualityBaseEpisodeURL = trimmedEpisodeURL
        if resetSelection {
            selectedQualityId = PlaybackQualityOption.autoIdentifier
        }
        
        qualityOptions = [autoOption]
        
        if let cached = qualityOptionCache[trimmedEpisodeURL] {
            // 缓存命中时直接复用，避免重复网络解析。
            qualityOptions = cached
            if resetSelection || !cached.contains(where: { $0.id == selectedQualityId }) {
                selectedQualityId = PlaybackQualityOption.autoIdentifier
            } else if previousSelected != selectedQualityId && cached.contains(where: { $0.id == previousSelected }) {
                selectedQualityId = previousSelected
            }
            return
        }
        
        let token = UUID()
        qualityResolveToken = token
        qualityResolveTask = Task { [trimmedEpisodeURL, resetSelection, previousSelected] in
            let resolved = await resolveQualityOptions(for: trimmedEpisodeURL)
            guard !Task.isCancelled else { return }
            guard qualityResolveToken == token, qualityBaseEpisodeURL == trimmedEpisodeURL else { return }
            guard !resolved.isEmpty else { return }
            
            qualityOptionCache[trimmedEpisodeURL] = resolved
            qualityOptions = resolved
            
            if resetSelection {
                selectedQualityId = PlaybackQualityOption.autoIdentifier
            } else if resolved.contains(where: { $0.id == selectedQualityId }) {
                // 当前选择仍有效，保持不变
            } else if resolved.contains(where: { $0.id == previousSelected }) {
                selectedQualityId = previousSelected
            } else {
                selectedQualityId = PlaybackQualityOption.autoIdentifier
            }
        }
    }
    
    /// 尝试从 HLS 主播放列表解析多清晰度选项。
    private func resolveQualityOptions(for episodeURL: String) async -> [PlaybackQualityOption] {
        guard let url = URL(string: episodeURL), Self.looksLikeHLSURL(url) else { return [] }
        guard let playlist = try? await network.getString(from: episodeURL) else { return [] }
        return Self.parseMasterPlaylist(playlist, masterURL: url)
    }
    
    /// HLS 变体流中间模型。
    private struct HLSVariant {
        let url: String
        let name: String?
        let height: Int?
        let bandwidth: Int?
    }
    
    /// 轻量判断 URL 是否可能是 HLS 播放列表。
    private static func looksLikeHLSURL(_ url: URL) -> Bool {
        let lowercased = url.absoluteString.lowercased()
        if lowercased.contains(".m3u8") { return true }
        let ext = url.pathExtension.lowercased()
        return ext == "m3u8" || ext == "m3u"
    }
    
    /// 解析 HLS 主播放列表并生成清晰度选项。
    /// 仅当解析出 2 个及以上有效变体时才返回（否则不显示清晰度切换）。
    private static func parseMasterPlaylist(_ content: String, masterURL: URL) -> [PlaybackQualityOption] {
        guard content.localizedCaseInsensitiveContains("#EXT-X-STREAM-INF") else { return [] }
        
        let lines = content.components(separatedBy: .newlines)
        var variants: [HLSVariant] = []
        var index = 0
        
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("#EXT-X-STREAM-INF:") else {
                index += 1
                continue
            }
            
            let attributeString = String(line.dropFirst("#EXT-X-STREAM-INF:".count))
            let attributes = parseAttributeMap(attributeString)
            
            var uri: String?
            var nextIndex = index + 1
            while nextIndex < lines.count {
                let candidate = lines[nextIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                if candidate.isEmpty {
                    nextIndex += 1
                    continue
                }
                if candidate.hasPrefix("#") {
                    nextIndex += 1
                    continue
                }
                uri = candidate
                break
            }
            
            if let uri, !uri.isEmpty {
                let resolvedURL = URL(string: uri, relativeTo: masterURL)?.absoluteURL.absoluteString ?? uri
                let name = attributes["NAME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                let bandwidth = attributes["BANDWIDTH"].flatMap(Int.init)
                let height: Int?
                if let resolution = attributes["RESOLUTION"] {
                    let parts = resolution.split(separator: "x")
                    if parts.count == 2 {
                        height = Int(parts[1])
                    } else {
                        height = nil
                    }
                } else {
                    height = nil
                }
                
                variants.append(HLSVariant(
                    url: resolvedURL,
                    name: name?.isEmpty == true ? nil : name,
                    height: height,
                    bandwidth: bandwidth
                ))
            }
            
            index = nextIndex + 1
        }
        
        guard !variants.isEmpty else { return [] }
        
        var seenURLs = Set<String>()
        let deduped = variants.filter { variant in
            let inserted = seenURLs.insert(variant.url).inserted
            return inserted
        }
        
        let sorted = deduped.sorted { lhs, rhs in
            let lhsHeight = lhs.height ?? -1
            let rhsHeight = rhs.height ?? -1
            if lhsHeight != rhsHeight {
                return lhsHeight > rhsHeight
            }
            let lhsBandwidth = lhs.bandwidth ?? -1
            let rhsBandwidth = rhs.bandwidth ?? -1
            if lhsBandwidth != rhsBandwidth {
                return lhsBandwidth > rhsBandwidth
            }
            return lhs.url < rhs.url
        }
        
        let masterURLString = masterURL.absoluteString
        var displayNameCount: [String: Int] = [:]
        let options = sorted.enumerated().map { offset, variant -> PlaybackQualityOption in
            let baseName: String
            if let name = variant.name, !name.isEmpty {
                baseName = name
            } else if let height = variant.height {
                baseName = "\(height)p"
            } else if let bandwidth = variant.bandwidth, bandwidth > 0 {
                baseName = "\(bandwidth / 1000)K"
            } else {
                baseName = "清晰度\(offset + 1)"
            }
            
            let newCount = (displayNameCount[baseName] ?? 0) + 1
            displayNameCount[baseName] = newCount
            let finalName = newCount > 1 ? "\(baseName) \(newCount)" : baseName
            
            return PlaybackQualityOption(id: variant.url, name: finalName, url: variant.url)
        }.filter { !$0.url.isEmpty && $0.url != masterURLString }
        
        guard options.count >= 2 else { return [] }
        
        var merged = [PlaybackQualityOption.auto(url: masterURLString)]
        merged.append(contentsOf: options)
        return merged
    }
    
    /// 解析 `EXT-X-STREAM-INF` 的属性串为键值字典。
    private static func parseAttributeMap(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        let pairs = splitAttributes(raw)
        for pair in pairs {
            let components = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard components.count == 2 else { continue }
            let key = String(components[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            var value = String(components[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value.removeFirst()
                value.removeLast()
            }
            if !key.isEmpty {
                result[key] = value
            }
        }
        return result
    }
    
    /// 按逗号分隔属性，但保留引号内逗号。
    private static func splitAttributes(_ raw: String) -> [String] {
        var parts: [String] = []
        var buffer = ""
        var inQuotes = false
        
        for char in raw {
            if char == "\"" {
                inQuotes.toggle()
                buffer.append(char)
                continue
            }
            
            if char == "," && !inQuotes {
                let item = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !item.isEmpty {
                    parts.append(item)
                }
                buffer.removeAll(keepingCapacity: true)
                continue
            }
            
            buffer.append(char)
        }
        
        let tail = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            parts.append(tail)
        }
        return parts
    }
}
