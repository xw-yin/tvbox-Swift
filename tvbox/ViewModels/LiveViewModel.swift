import Foundation
import SwiftUI
import Combine

/// 直播 ViewModel
@MainActor
class LiveViewModel: ObservableObject {
    /// 全部频道分组。
    @Published var channelGroups: [LiveChannelGroup] = []
    /// 当前选中分组索引。
    @Published var selectedGroupIndex: Int = 0
    /// 当前选中频道索引（相对于当前分组）。
    @Published var selectedChannelIndex: Int = 0
    /// 用户收藏的直播频道（持久化）。
    @Published var favoriteChannels: [LiveChannelItem] = []
    /// 当前播放频道。
    @Published var currentChannel: LiveChannelItem?
    /// 当前频道节目单（预留）。
    @Published var epgList: [Epginfo] = []
    /// 加载状态（预留，便于后续接入远程 EPG）。
    @Published var isLoading = false
    /// 是否显示频道列表（预留给 TV 遥控交互）。
    @Published var showChannelList = false
    
    /// 订阅配置更新，支持直播频道列表实时刷新。
    private var cancellables: Set<AnyCancellable> = []
    
    init() {
        self.favoriteChannels = Self.loadFavoriteChannels()
        bindLiveChannelGroups()
    }
    
    /// 加载直播频道
    func loadChannels() {
        applyChannelGroups(ApiConfig.shared.liveChannelGroupList)
    }
    
    /// 选择频道分组
    func selectGroup(_ index: Int) {
        let groups = displayedGroups
        guard index >= 0, index < groups.count else { return }
        selectedGroupIndex = index
        selectedChannelIndex = 0
        if let first = groups[index].channels.first {
            selectChannel(first)
        }
    }
    
    /// 选择频道
    func selectChannel(_ channel: LiveChannelItem) {
        currentChannel = channel
        loadEPG(for: channel)
    }
    
    /// 上一个频道
    func previousChannel() {
        let groups = displayedGroups
        guard !groups.isEmpty else { return }
        if selectedChannelIndex > 0 {
            selectedChannelIndex -= 1
        } else if selectedGroupIndex > 0 {
            selectedGroupIndex -= 1
            selectedChannelIndex = groups[selectedGroupIndex].channels.count - 1
        }
        if let ch = groups[selectedGroupIndex].channels[safe: selectedChannelIndex] {
            selectChannel(ch)
        }
    }
    
    /// 下一个频道
    func nextChannel() {
        let groups = displayedGroups
        guard !groups.isEmpty else { return }
        let group = groups[selectedGroupIndex]
        if selectedChannelIndex < group.channels.count - 1 {
            selectedChannelIndex += 1
        } else if selectedGroupIndex < groups.count - 1 {
            selectedGroupIndex += 1
            selectedChannelIndex = 0
        }
        if let ch = groups[selectedGroupIndex].channels[safe: selectedChannelIndex] {
            selectChannel(ch)
        }
    }
    
    /// 切换线路
    func switchSource() {
        // `currentChannel` 为值类型，调用 mutating 方法会触发 @Published 重新发布。
        currentChannel?.nextSource()
    }
    
    /// 当前频道列表
    var currentChannels: [LiveChannelItem] {
        let groups = displayedGroups
        guard selectedGroupIndex < groups.count else { return [] }
        return groups[selectedGroupIndex].channels
    }

    // MARK: - 频道收藏

    private static let favoriteChannelsKey = "liveFavChannels"

    /// 展示用分组：收藏非空时在首位插入「我的收藏」分组（groupIndex = -1 标识）。
    /// 注意 selectedGroupIndex 始终以 displayedGroups 为基准，收藏分组出现/消失时
    /// toggleFavorite 内会同步修正索引，避免真实分组错位。
    var displayedGroups: [LiveChannelGroup] {
        guard !favoriteChannels.isEmpty else { return channelGroups }
        var favGroup = LiveChannelGroup()
        favGroup.groupName = "我的收藏"
        favGroup.groupIndex = -1
        favGroup.channels = favoriteChannels
        return [favGroup] + channelGroups
    }

    /// 是否为合成的收藏分组。
    func isFavoritesGroup(_ group: LiveChannelGroup) -> Bool {
        group.groupIndex == -1
    }

    /// 收藏标识：频道名 + 首个播放地址，规避跨分组同名冲突。
    static func favKey(_ channel: LiveChannelItem) -> String {
        channel.channelName + "|" + (channel.channelUrls.first ?? "")
    }

    /// 是否已收藏。
    func isFavorite(_ channel: LiveChannelItem) -> Bool {
        let key = Self.favKey(channel)
        return favoriteChannels.contains(where: { Self.favKey($0) == key })
    }

    /// 收藏 / 取消收藏，并同步修正 selectedGroupIndex。
    func toggleFavorite(_ channel: LiveChannelItem) {
        let key = Self.favKey(channel)
        if let idx = favoriteChannels.firstIndex(where: { Self.favKey($0) == key }) {
            favoriteChannels.remove(at: idx)
            if favoriteChannels.isEmpty, selectedGroupIndex == 0 {
                // 收藏分组消失：index 0 已变为首个真实分组，重置频道索引。
                selectedChannelIndex = 0
            }
        } else {
            let wasEmpty = favoriteChannels.isEmpty
            favoriteChannels.append(channel)
            if wasEmpty {
                // 收藏分组出现：真实分组索引整体 +1。
                selectedGroupIndex += 1
            }
        }
        Self.saveFavoriteChannels(favoriteChannels)
    }

    private static func loadFavoriteChannels() -> [LiveChannelItem] {
        guard let data = UserDefaults.standard.data(forKey: favoriteChannelsKey),
              let list = try? JSONDecoder().decode([LiveChannelItem].self, from: data) else {
            return []
        }
        return list
    }

    private static func saveFavoriteChannels(_ channels: [LiveChannelItem]) {
        if let data = try? JSONEncoder().encode(channels) {
            UserDefaults.standard.set(data, forKey: favoriteChannelsKey)
        }
    }
    
    /// 加载 EPG 节目单
    private func loadEPG(for channel: LiveChannelItem) {
        let channelName = channel.channelName
        // 先清空，避免展示上个频道的节目单。
        epgList = []
        Task {
            let programs = await EpgService.shared.programs(for: channelName)
            await MainActor.run {
                // 切台过程中丢弃旧请求结果。
                guard self.currentChannel?.channelName == channelName else { return }
                self.epgList = programs
            }
        }
    }

    /// 当前正在播出的节目（无 EPG 数据时为 nil）。
    var currentProgram: Epginfo? {
        epgList.first(where: { $0.isLive })
    }

    /// 当前节目之后的下一个节目（无 EPG 数据时为 nil）。
    var nextProgram: Epginfo? {
        guard let current = currentProgram,
              let index = epgList.firstIndex(where: { $0.id == current.id }),
              index + 1 < epgList.count else { return nil }
        return epgList[index + 1]
    }
    
    private func bindLiveChannelGroups() {
        ApiConfig.shared.$liveChannelGroupList
            .sink { [weak self] groups in
                self?.applyChannelGroups(groups)
            }
            .store(in: &cancellables)
    }
    
    private func applyChannelGroups(_ groups: [LiveChannelGroup]) {
        let previousChannelId = currentChannel?.id
        channelGroups = groups
        
        guard !groups.isEmpty else {
            selectedGroupIndex = 0
            selectedChannelIndex = 0
            currentChannel = nil
            return
        }
        
        if let previousChannelId,
           let located = locateChannel(withId: previousChannelId, in: groups) {
            selectedGroupIndex = located.groupIndex
            selectedChannelIndex = located.channelIndex
            currentChannel = groups[located.groupIndex].channels[located.channelIndex]
            return
        }
        
        let clampedGroupIndex = min(max(0, selectedGroupIndex), groups.count - 1)
        selectedGroupIndex = clampedGroupIndex
        
        let channels = groups[clampedGroupIndex].channels
        guard !channels.isEmpty else {
            selectedChannelIndex = 0
            currentChannel = nil
            return
        }
        
        let clampedChannelIndex = min(max(0, selectedChannelIndex), channels.count - 1)
        selectedChannelIndex = clampedChannelIndex
        currentChannel = channels[clampedChannelIndex]
    }
    
    private func locateChannel(
        withId channelId: String,
        in groups: [LiveChannelGroup]
    ) -> (groupIndex: Int, channelIndex: Int)? {
        for (groupIndex, group) in groups.enumerated() {
            if let channelIndex = group.channels.firstIndex(where: { $0.id == channelId }) {
                return (groupIndex, channelIndex)
            }
        }
        return nil
    }
}

// 安全数组下标访问
extension Collection {
    /// 安全下标读取，越界时返回 `nil`。
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
