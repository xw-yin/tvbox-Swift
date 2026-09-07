import SwiftUI

/// 首页 - 对应 Android 版 HomeActivity + UserFragment
struct HomeView: View {
    @StateObject private var viewModel = HomeViewModel()
    @ObservedObject private var apiConfig = ApiConfig.shared
    @EnvironmentObject var appState: AppState
    @State private var categoryScrollAnchorId: String?
    @State private var isHeaderCollapsed = false
    
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
            GeometryReader { viewport in
                ScrollView {
                    VStack(spacing: 0) {
                        HStack(alignment: .center, spacing: 16) {
                            Text("发现")
                                .font(.largeTitle.bold())
                                .accessibilityAddTraits(.isHeader)
                            Spacer(minLength: 12)
                            sourceMenu
                                .padding(.horizontal, 14)
                                .frame(height: 44)
                                .liquidControl()
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 4)
                        .padding(.bottom, 14)
                        .background {
                            GeometryReader { header in
                                Color.clear.preference(
                                    key: HomeHeaderOffsetKey.self,
                                    value: header.frame(in: .named("homeScroll")).maxY
                                )
                            }
                        }
                        if !viewModel.sorts.isEmpty {
                            categoryTabBar
                        }
                        contentArea
                            .frame(minHeight: max(240, viewport.size.height))
                    }
                }
                .coordinateSpace(name: "homeScroll")
                .onPreferenceChange(HomeHeaderOffsetKey.self) { bottom in
                    isHeaderCollapsed = bottom < 12
                }
                .refreshable { await viewModel.refresh() }
            }
            .background(AppTheme.pageBackground.ignoresSafeArea())
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                if isHeaderCollapsed {
                    ToolbarItem(placement: .principal) {
                        Text("发现").font(.headline)
                    }
                    ToolbarItem(placement: .primaryAction) { sourceMenu }
                }
            }
            .navigationDestination(for: Movie.Video.self) { video in
                DetailView(video: video)
            }

        }
        .task(id: "\(appState.configRevision):\(appState.currentSourceKey)") {
            guard appState.isConfigLoaded else { return }
            viewModel.selectedSort = nil
            viewModel.sorts = []
            viewModel.homeVideos = []
            await viewModel.refresh()
            if let first = viewModel.sorts.first {
                viewModel.selectSort(first)
            }
        }
    }
    
    // MARK: - 顶部栏（源选择器）
    
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
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "play.tv").foregroundStyle(AppTheme.accent)
                    Text(apiConfig.homeSourceBean?.name ?? "切换站点")
                        .font(.subheadline.weight(.semibold)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("切换站点")
    }

    // MARK: - 分类标签栏
    
    private var categoryTabBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(viewModel.sorts) { sort in
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                viewModel.selectSort(sort)
                            }
                            categoryScrollAnchorId = sort.id
                            scrollCategoryBar(to: sort.id, proxy: proxy)
                        } label: {
                            Text(sort.name)
                                .font(.subheadline.weight(viewModel.selectedSort?.id == sort.id ? .semibold : .regular))
                                .foregroundStyle(viewModel.selectedSort?.id == sort.id ? Color.white : Color.secondary)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 11)
                                .liquidControl(radius: 24)
                                .overlay {
                                    Capsule().strokeBorder(
                                        viewModel.selectedSort?.id == sort.id ? AppTheme.accent : .clear,
                                        lineWidth: 1.5
                                    )
                                }
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
                }
            } else if let error = viewModel.errorMessage, viewModel.categoryVideos.isEmpty && viewModel.homeVideos.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(AppTheme.accent)
                    Text(error)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                    
                    // 如果是不支持的源类型，显示类型信息
                    if let source = ApiConfig.shared.homeSourceBean, !source.isSupportedInSwift {
                        Text("当前源类型: \(source.typeDescription)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Button("重试") {
                        Task { await viewModel.refresh() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.accent)
                    Spacer()
                }
            } else {
                let videos = viewModel.selectedSort?.id == "home"
                    ? viewModel.homeVideos
                    : viewModel.categoryVideos
                
                if videos.isEmpty && !viewModel.isLoading {
                    ContentUnavailableView {
                        Label("这里还没有影片", systemImage: "film.stack")
                    } description: {
                        Text("试试其他分类，或从右上角切换片库。")
                    } actions: {
                        Button("刷新片库") { Task { await viewModel.refresh() } }
                            .buttonStyle(.bordered)
                    }
                } else {
                VStack(spacing: 0) {
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
}


private struct HomeHeaderOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = .greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
