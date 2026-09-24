import SwiftUI
import SwiftData

/// 首页 - 对应 Android 版 HomeActivity + UserFragment
struct HomeView: View {
    @Query(sort: \VodRecord.updateTime, order: .reverse) private var records: [VodRecord]
    @StateObject private var viewModel = HomeViewModel()
    @ObservedObject private var apiConfig = ApiConfig.shared
    @EnvironmentObject var appState: AppState
    @State private var categoryScrollAnchorId: String?
    @State private var showAddPage = false
    @State private var showSourceManagement = false
    
    // 网格布局
    #if os(iOS)
    private let columns = [
        GridItem(.adaptive(minimum: 108, maximum: 170), spacing: 14)
    ]
    #else
    private let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 16)
    ]
    #endif
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                headerBar
                    .background(AppTheme.pageBackground)
                
                if !viewModel.sorts.isEmpty {
                    categoryTabBar
                        .background(AppTheme.pageBackground)
                }

                if shouldShowFilterBar {
                    filterBar
                        .background(AppTheme.pageBackground)
                }
                
                ScrollView {
                    contentArea
                }
                .refreshable {
                    if !appState.isConfigLoaded && appState.configLoadError != nil {
                        await appState.reloadSavedConfig()
                    } else {
                        await viewModel.refresh(force: true)
                    }
                }
            }
            .background(AppTheme.pageBackground.ignoresSafeArea())
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
            .navigationDestination(for: Movie.Video.self) { video in
                DetailView(video: video)
            }
            .sheet(isPresented: $showAddPage) {
                AddPageSheet()
            }
            .sheet(isPresented: $showSourceManagement) {
                NavigationStack {
                    SettingsView(sourcesOnly: true)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("完成") { showSourceManagement = false }
                            }
                        }
                }
            }
        }
        .task(id: "\(appState.configRevision):\(appState.currentSourceKey)") {
            guard appState.isConfigLoaded else { return }
            await viewModel.loadForSource(key: appState.currentSourceKey)
        }
    }
    
    // MARK: - 顶部栏（大标题与源选择器）
    
    private var headerBar: some View {
        HStack(alignment: .center, spacing: 16) {
            Text("首页")
                .font(.largeTitle.bold())
                .foregroundColor(.white)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 12)
            sourceMenu
                .padding(.horizontal, 14)
                .frame(height: 44)
                .liquidControl(radius: 22)
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }
    
    private var sourceMenu: some View {
        Menu {
            if apiConfig.sourceBeanList.isEmpty {
                Button("暂无站点，请先在源管理添加订阅") {}
                    .disabled(true)
            }
            ForEach(apiConfig.sourceBeanList) { source in
                Button {
                    apiConfig.setHomeSource(source)
                    appState.currentSourceKey = source.key
                } label: {
                    if source.key == apiConfig.homeSourceBean?.key {
                        Label(source.name, systemImage: "checkmark")
                    } else {
                        Text(source.isSupportedInSwift ? source.name : "\(source.name)（暂不支持）")
                    }
                }
                .disabled(!source.isSupportedInSwift)
            }
            
            Divider()
            
            Button {
                showAddPage = true
            } label: {
                Label("添加页面 / 扩展…", systemImage: "plus.circle")
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "play.tv").foregroundStyle(AppTheme.accent)
                Text(apiConfig.homeSourceBean?.name ?? "切换站点")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.white.opacity(0.7))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("切换站点")
    }

    // MARK: - 继续观看

    /// 最近有播放进度的历史记录（最多 10 条），横滑展示。
    private var continueWatchingItems: [VodRecord] {
        records.filter { !$0.playNote.isEmpty }.prefix(10).map { $0 }
    }

    @ViewBuilder
    private var continueWatchingRow: some View {
        let items = continueWatchingItems
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("继续观看")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                    Spacer()
                    NavigationLink(destination: HistoryView()) {
                        Text("全部")
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(items) { item in
                            NavigationLink(value: continueWatchingVideo(from: item)) {
                                continueWatchingCard(item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
            .padding(.top, 12)
            .padding(.bottom, 4)
        }
    }

    private func continueWatchingCard(_ item: VodRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                CachedAsyncImage(url: URL.posterURL(from: item.vodPic)) { image in
                    image.resizable().aspectRatio(16/10, contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(Color.gray.opacity(0.3))
                        .aspectRatio(16/10, contentMode: .fill)
                }
                .frame(width: 168)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                if !item.playNote.isEmpty {
                    Text(item.playNote)
                        .font(.system(size: 9))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.7))
                        .cornerRadius(4)
                        .padding(6)
                }
            }
            .overlay(alignment: .bottom) {
                if let fraction = CacheStore.decodePlaybackState(item.dataJson)?.progressFraction {
                    GeometryReader { geo in
                        Rectangle()
                            .fill(AppTheme.accentGradient)
                            .frame(width: geo.size.width * fraction, height: 3)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    }
                    .frame(height: 3)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(item.vodName)
                .font(.caption)
                .foregroundColor(.white)
                .lineLimit(1)
                .frame(width: 168, alignment: .leading)
        }
    }

    private func continueWatchingVideo(from item: VodRecord) -> Movie.Video {
        Movie.Video(id: item.vodId, name: item.vodName, pic: item.vodPic, sourceKey: item.sourceKey)
    }

    // MARK: - 分类标签栏
    
    private var categoryTabBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(viewModel.sorts) { sort in
                        Button {
                            HapticManager.shared.selection()
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                viewModel.selectSort(sort)
                            }
                            categoryScrollAnchorId = sort.id
                            scrollCategoryBar(to: sort.id, proxy: proxy)
                        } label: {
                            Text(sort.name)
                                .font(.subheadline.weight(viewModel.selectedSort?.id == sort.id ? .semibold : .medium))
                                .foregroundStyle(viewModel.selectedSort?.id == sort.id ? Color.white : Color.white.opacity(0.7))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .liquidControl(radius: 20, isSelected: viewModel.selectedSort?.id == sort.id)
                        }
                        .buttonStyle(.plain)
                        .id(sort.id)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }
            .onAppear {
                syncCategoryScrollAnchorIfNeeded()
                scrollCategoryBar(to: categoryScrollAnchorId, proxy: proxy, animated: false)
            }
            .onChange(of: viewModel.sorts.map(\.id)) { oldValue, newValue in
                syncCategoryScrollAnchorIfNeeded()
                scrollCategoryBar(to: categoryScrollAnchorId, proxy: proxy, animated: false)
            }
            .onChange(of: viewModel.selectedSort?.id) { oldId, newId in
                guard let newId else { return }
                categoryScrollAnchorId = newId
                scrollCategoryBar(to: newId, proxy: proxy)
            }
        }
        .padding(.bottom, 4)
    }

    // MARK: - 筛选栏

    /// 当前分类带有筛选定义（且非"推荐"分类）时显示筛选栏。
    private var shouldShowFilterBar: Bool {
        guard let sort = viewModel.selectedSort, sort.id != "home" else { return false }
        return !sort.filters.isEmpty
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(viewModel.selectedSort?.filters ?? [], id: \.key) { filter in
                filterRow(filter)
            }
            if !viewModel.activeFilters.isEmpty {
                Button {
                    HapticManager.shared.selection()
                    viewModel.clearFilters()
                } label: {
                    Text("清除筛选")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(AppTheme.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private func filterRow(_ filter: MovieSort.SortFilter) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(filter.name)
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.white.opacity(0.6))
                .frame(width: 40, alignment: .leading)
                .padding(.top, 8)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(filter.values, id: \.v) { value in
                        let isSelected = viewModel.activeFilters[filter.key] == value.v
                        Button {
                            HapticManager.shared.selection()
                            viewModel.setFilterValue(value.v, forKey: filter.key)
                        } label: {
                            Text(value.n)
                                .font(.caption.weight(isSelected ? .semibold : .regular))
                                .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.7))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .liquidControl(radius: 14, isSelected: isSelected)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
    
    private func categoryIndex(for id: String?) -> Int? {
        guard let id else { return nil }
        return viewModel.sorts.firstIndex(where: { $0.id == id })
    }
    
    private func syncCategoryScrollAnchorIfNeeded() {
        guard !viewModel.sorts.isEmpty else {
            categoryScrollAnchorId = nil
            return
        }
        
        if let selectedId = viewModel.selectedSort?.id,
           viewModel.sorts.contains(where: { $0.id == selectedId }) {
            categoryScrollAnchorId = selectedId
            return
        }
        
        if let anchorId = categoryScrollAnchorId,
           viewModel.sorts.contains(where: { $0.id == anchorId }) {
            return
        }
        
        categoryScrollAnchorId = viewModel.sorts.first?.id
    }
    
    private func scrollCategoryBar(to id: String?, proxy: ScrollViewProxy, animated: Bool = true) {
        guard let id else { return }
        
        if animated {
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(id, anchor: .center)
            }
        } else {
            proxy.scrollTo(id, anchor: .center)
        }
    }
    
    // MARK: - 内容区
    
    private var contentArea: some View {
        Group {
            if appState.isLoadingConfig || (viewModel.isLoading && viewModel.categoryVideos.isEmpty && viewModel.homeVideos.isEmpty) {
                VStack {
                    Spacer()
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(AppTheme.accent)
                    Text(appState.isLoadingConfig ? "正在加载上次使用的订阅源…" : "正在加载影片…")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.top, 12)
                    Spacer()
                    Spacer().frame(height: 50)
                }
                .frame(maxWidth: .infinity)
                .containerRelativeFrame(.vertical)
            } else if !appState.isLoadingConfig, let configError = appState.configLoadError, viewModel.categoryVideos.isEmpty && viewModel.homeVideos.isEmpty {
                UnifiedEmptyStateView(
                    icon: "network.slash",
                    title: "订阅源加载失败",
                    message: configError,
                    bottomSpacerHeight: 50
                ) {
                    EmptyPrimaryButton(title: "重试", icon: "arrow.clockwise") {
                        Task { await appState.reloadSavedConfig() }
                    }
                    EmptySecondaryButton(title: "源管理", icon: "server.rack") {
                        showSourceManagement = true
                    }
                }
            } else if let error = viewModel.errorMessage, viewModel.categoryVideos.isEmpty && viewModel.homeVideos.isEmpty {
                let extraSourceInfo: String? = {
                    if let source = ApiConfig.shared.homeSourceBean, !source.isSupportedInSwift {
                        return "当前源类型: \(source.typeDescription)"
                    }
                    return nil
                }()
                UnifiedEmptyStateView(
                    icon: "exclamationmark.triangle",
                    title: "数据加载失败",
                    message: error,
                    extraInfo: extraSourceInfo,
                    bottomSpacerHeight: 50
                ) {
                    EmptyPrimaryButton(title: "重试", icon: "arrow.clockwise") {
                        Task { await viewModel.refresh() }
                    }
                    EmptySecondaryButton(title: "源管理", icon: "server.rack") {
                        showSourceManagement = true
                    }
                }
            } else {
                let videos = viewModel.selectedSort?.id == "home"
                    ? viewModel.homeVideos
                    : viewModel.categoryVideos
                
                if videos.isEmpty && !viewModel.isLoading {
                    UnifiedEmptyStateView(
                        icon: "film.stack",
                        title: "这里还没有影片",
                        message: "试试其他分类，或从右上角切换片库。",
                        iconColor: .white.opacity(0.4),
                        bottomSpacerHeight: 50
                    ) {
                        EmptyPrimaryButton(title: "刷新片库", icon: "arrow.clockwise") {
                            Task { await viewModel.refresh() }
                        }
                        EmptySecondaryButton(title: "源管理", icon: "server.rack") {
                            showSourceManagement = true
                        }
                    }
                } else {
                    continueWatchingRow
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(videos) { video in
                            NavigationLink(value: video) {
                                VodCardView(video: video)
                            }
                            #if os(iOS)
                            .buttonStyle(VodCardPressStyle())
                            #else
                            .buttonStyle(.plain)
                            #endif
                            .onAppear {
                                Task { await viewModel.loadMoreIfNeeded(currentItem: video) }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    #if os(iOS)
                    .padding(.bottom, 84)
                    #endif
                    
                    // 加载更多
                    if viewModel.selectedSort?.id != "home" && viewModel.hasMore {
                        ProgressView()
                            .padding()
                    }
                }
            }
        }
    }
}
