import SwiftUI

/// 首页 - 对应 Android 版 HomeActivity + UserFragment
struct HomeView: View {
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
                
                ScrollView {
                    contentArea
                        #if os(iOS)
                        .padding(.bottom, 84)
                        #endif
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
                .frame(maxWidth: .infinity, minHeight: 320)
            } else if !appState.isLoadingConfig, let configError = appState.configLoadError, viewModel.categoryVideos.isEmpty && viewModel.homeVideos.isEmpty {
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "network.slash")
                        .font(.system(size: 48))
                        .foregroundColor(AppTheme.accent)
                    Text("订阅源加载失败")
                        .font(.title3.bold())
                        .foregroundColor(.white)
                    Text(configError)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 36)
                        .lineLimit(4)
                    
                    HStack(spacing: 14) {
                        Button {
                            Task { await appState.reloadSavedConfig() }
                        } label: {
                            Label("重试", systemImage: "arrow.clockwise")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AppTheme.accent)
                        
                        Button {
                            showSourceManagement = true
                        } label: {
                            Label("源管理", systemImage: "server.rack")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.bordered)
                        .tint(.white)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: 320)
            } else if let error = viewModel.errorMessage, viewModel.categoryVideos.isEmpty && viewModel.homeVideos.isEmpty {
                VStack(spacing: 14) {
                    Spacer()
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 48))
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
                    
                    HStack(spacing: 14) {
                        Button {
                            Task { await viewModel.refresh() }
                        } label: {
                            Label("重试", systemImage: "arrow.clockwise")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AppTheme.accent)
                        
                        Button {
                            showSourceManagement = true
                        } label: {
                            Label("源管理", systemImage: "server.rack")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.bordered)
                        .tint(.white)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: 320)
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
                        HStack(spacing: 12) {
                            Button("刷新片库") { Task { await viewModel.refresh() } }
                                .buttonStyle(.borderedProminent)
                                .tint(AppTheme.accent)
                            Button("源管理") { showSourceManagement = true }
                                .buttonStyle(.bordered)
                                .tint(.white)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 320)
                } else {
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
