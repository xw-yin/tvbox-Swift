import SwiftUI

/// 首页 - 对应 Android 版 HomeActivity + UserFragment
struct HomeView: View {
    @StateObject private var viewModel = HomeViewModel()
    @EnvironmentObject var appState: AppState
    @State private var categoryScrollAnchorId: String?
    
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
                
                // 分类标签栏
                if !viewModel.sorts.isEmpty {
                    categoryTabBar
                }
                
                // 内容区
                contentArea
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppTheme.pageBackground.ignoresSafeArea())
            .navigationTitle("发现")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) { headerBar }
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
    
    private var headerBar: some View {
        HStack(spacing: 12) {
            // 源切换按钮
            Menu {
                ForEach(ApiConfig.shared.sourceBeanList.filter { $0.isSupportedInSwift }) { source in
                    Button {
                        ApiConfig.shared.setHomeSource(source)
                        appState.currentSourceKey = source.key
                    } label: {
                        HStack {
                            Text(source.name)
                            if source.key == ApiConfig.shared.homeSourceBean?.key {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "play.tv.fill")
                        .font(.system(size: 14))
                        .foregroundColor(AppTheme.accent)
                    Text(ApiConfig.shared.homeSourceBean?.name ?? "TVBox")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            
        }
    }
    
    // MARK: - 分类标签栏
    
    private var categoryTabBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
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
                                .background {
                                    if viewModel.selectedSort?.id == sort.id {
                                        Capsule().fill(.white.opacity(0.12))
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .id(sort.id)
                    }
                }
                .padding(.horizontal, 12)
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
            if viewModel.isLoading && viewModel.categoryVideos.isEmpty && viewModel.homeVideos.isEmpty {
                VStack {
                    Spacer()
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(AppTheme.accent)
                    Text("加载中...")
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
                ScrollView {
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
                .refreshable {
                    await viewModel.refresh()
                }
                }
            }
        }
        .navigationDestination(for: Movie.Video.self) { video in
            DetailView(video: video)
        }
    }
}

