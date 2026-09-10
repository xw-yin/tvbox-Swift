import SwiftUI

/// 根视图 - 对应 Android 版 HomeActivity 的 TabView 导航
struct ContentView: View {
    /// 首次配置页点击“最近使用”时，当前要写入的输入框目标。
    private enum ApiInputTarget {
        case vod
        case live
    }
    
    /// 全局状态（配置加载、分栏状态等）。
    @EnvironmentObject var appState: AppState
    /// 网络连接状态。
    @EnvironmentObject var networkMonitor: NetworkMonitor
    /// 设置页 ViewModel。根视图复用它处理首次配置与多仓库选择。
    @StateObject private var settingsVM = SettingsViewModel()
    /// 当前主标签索引。
    @State private var selectedTab = 0
    /// 已保存地址独立于本次网络加载结果，避免重启时再次显示首次配置。
    @AppStorage(HawkConfig.API_URL) private var savedVodUrl = ""
    @State private var showSourceManagement = false
    /// 首次配置页历史回填目标输入框。
    @State private var setupInputTarget: ApiInputTarget = .vod
    
    var body: some View {
        Group {
            if appState.isConfigLoaded || !savedVodUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                mainTabView
            } else {
                setupView
            }
        }
        .overlay(multiRepoSelectionOverlay)
        .overlay(alignment: .top) {
            networkStatusBanner
        }
        .preferredColorScheme(.dark)
        .safeAreaInset(edge: .top) {
            if !savedVodUrl.isEmpty {
                configStatusBar
            }
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
        .task {
            await appState.restoreSavedConfigIfNeeded()
        }
    }
    
    @ViewBuilder
    private var configStatusBar: some View {
        if !appState.isLoadingConfig, let error = appState.configLoadError {
            VStack(alignment: .leading, spacing: 8) {
                Text("订阅源加载失败，已保留原地址")
                    .font(.subheadline.bold())
                Text(error).font(.caption).lineLimit(2)
                HStack {
                    Button("重试") {
                        Task { await appState.reloadSavedConfig() }
                    }
                    Button("源管理") { showSourceManagement = true }
                }
                .buttonStyle(.bordered)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial)
        }
    }

    @ViewBuilder
    private var multiRepoSelectionOverlay: some View {
        // 若配置地址解析出“多仓库入口”，在根层统一弹窗，避免被子页面导航遮挡。
        if let pending = settingsVM.pendingMultiRepoSelection {
            SelectionModal(
                title: "选择\(pending.target.title)仓库",
                icon: "list.bullet.rectangle.portrait.fill",
                items: pending.options,
                selectedItem: nil,
                itemTitle: { $0.name },
                onSelect: { option in
                    Task {
                        await settingsVM.selectPendingMultiRepoOption(option)
                        if settingsVM.configSuccess {
                            appState.applyLoadedConfigState()
                        }
                    }
                },
                onCancel: {
                    settingsVM.cancelPendingMultiRepoSelection()
                }
            )
        }
    }
    
    // MARK: - 主界面
    
    /// 主体导航容器：iOS 使用 TabView，macOS 使用 NavigationSplitView。
    private var mainTabView: some View {
        #if os(iOS)
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {
                HomeView()
                    .tag(0)
                    .toolbar(.hidden, for: .tabBar)
                
                LiveView(onExit: {
                    selectedTab = 0
                })
                    .tag(1)
                    .toolbar(.hidden, for: .tabBar)
                
                SearchView()
                    .tag(2)
                    .toolbar(.hidden, for: .tabBar)
                
                ProfileView()
                    .tag(3)
                    .toolbar(.hidden, for: .tabBar)
            }
            
            // 悬浮双岛式分体 TabBar（系统液态超薄材质）
            if !appState.isTabBarHidden {
                floatingLiquidTabBar
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: appState.isTabBarHidden)
        .onChange(of: selectedTab) { _, _ in
            HapticManager.shared.selection()
        }
        #else
        NavigationSplitView(columnVisibility: $appState.splitViewVisibility) {
            List(selection: $selectedTab) {
                Label("首页", systemImage: "house.fill")
                    .tag(0)
                Label("直播", systemImage: "tv.fill")
                    .tag(1)
                Label("搜索", systemImage: "magnifyingglass")
                    .tag(2)
                Label("收藏", systemImage: "heart.fill")
                    .tag(3)
                Label("历史", systemImage: "clock.fill")
                    .tag(5)
                Label("设置", systemImage: "gearshape.fill")
                    .tag(4)
            }
            .navigationTitle("TVBox")
            .listStyle(.sidebar)
        } detail: {
            switch selectedTab {
            case 0: HomeView()
            case 1: LiveView()
            case 2: SearchView()
            case 3:
                NavigationStack {
                    FavoritesView()
                }
            case 4: NavigationStack { SettingsView() }
            case 5:
                NavigationStack {
                    HistoryView()
                }
            default: HomeView()
            }
        }
        #endif
    }
    
    // MARK: - 首次配置页面
    
    /// 首次启动或未加载配置时的引导页面。
    private var setupView: some View {
        ZStack {
            // 背景装饰
            AppTheme.pageBackground
                .ignoresSafeArea()
            
            ScrollView {
                VStack(spacing: 32) {
                    // Logo 区域
                    VStack(spacing: 20) {
                        Image(systemName: "play.tv")
                            .font(.system(size: 48, weight: .light))
                            .foregroundStyle(.white)
                            .frame(width: 112, height: 112)
                            .liquidControl(radius: 34)

                        VStack(spacing: 8) {
                            Text("你的影院，从这里开始")
                                .font(.largeTitle.bold())
                                .foregroundColor(.white)
                                .tracking(2)
                            
                            Text("添加订阅，发现喜欢的内容。\n只需设置一次，下次直接继续。")
                                .font(.subheadline)
                                .foregroundColor(.white.opacity(0.6))
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding(.top, 60)
                    
                    // 输入表单
                    VStack(spacing: 24) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("添加订阅")
                                .font(.headline)
                                .foregroundColor(.white)
                                .padding(.leading, 4)
                            
                            HStack {
                                Image(systemName: "link")
                                    .foregroundColor(AppTheme.accent)
                                TextField("点播订阅地址", text: $settingsVM.vodApiUrl)
                                    .textFieldStyle(.plain)
                                    .foregroundColor(.white)
                                    .onTapGesture {
                                        setupInputTarget = .vod
                                    }
                                    #if os(iOS)
                                    .autocapitalization(.none)
                                    .keyboardType(.URL)
                                    #endif
                                
                                Button {
                                    if let text = readPasteboardText() {
                                        settingsVM.vodApiUrl = text
                                    }
                                } label: {
                                    Image(systemName: "doc.on.clipboard")
                                        .foregroundColor(AppTheme.accent)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding()
                            .glassCard(cornerRadius: 15)
                            
                            HStack {
                                Image(systemName: "tv")
                                    .foregroundColor(AppTheme.accent)
                                TextField("直播订阅地址（选填）", text: $settingsVM.liveApiUrl)
                                    .textFieldStyle(.plain)
                                    .foregroundColor(.white)
                                    .onTapGesture {
                                        setupInputTarget = .live
                                    }
                                    #if os(iOS)
                                    .autocapitalization(.none)
                                    .keyboardType(.URL)
                                    #endif
                                
                                Button {
                                    if let text = readPasteboardText() {
                                        settingsVM.liveApiUrl = text
                                    }
                                } label: {
                                    Image(systemName: "doc.on.clipboard")
                                        .foregroundColor(AppTheme.accent)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding()
                            .glassCard(cornerRadius: 15)
                        }
                        
                        // 确认按钮
                        Button {
                            Task {
                                await settingsVM.loadConfig()
                                if settingsVM.configSuccess {
                                    appState.applyLoadedConfigState()
                                }
                            }
                        } label: {
                            HStack {
                                if settingsVM.isLoadingConfig {
                                    ProgressView()
                                        .tint(.white)
                                        .padding(.trailing, 8)
                                }
                                Text(settingsVM.isLoadingConfig ? "正在解析配置..." : "保存并开始")
                                    .fontWeight(.bold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(AppTheme.accentGradient)
                            .foregroundColor(.white)
                            .clipShape(Capsule())

                        }
                        .buttonStyle(.plain)
                        .disabled(
                            settingsVM.isLoadingConfig
                            || settingsVM.vodApiUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                        
                        // 历史记录
                        if !settingsVM.apiHistory.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("最近使用")
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.5))
                                    .padding(.horizontal, 4)
                                
                                ForEach(settingsVM.apiHistory.prefix(3), id: \.self) { url in
                                    Button {
                                        switch setupInputTarget {
                                        case .vod:
                                            settingsVM.vodApiUrl = url
                                        case .live:
                                            settingsVM.liveApiUrl = url
                                        }
                                    } label: {
                                        HStack {
                                            Image(systemName: "clock.arrow.2.circlepath")
                                                .font(.caption)
                                            Text(url)
                                                .font(.caption)
                                                .lineLimit(1)
                                            Spacer()
                                            Image(systemName: "chevron.right")
                                                .font(.system(size: 8))
                                        }
                                        .padding(.vertical, 10)
                                        .padding(.horizontal, 16)
                                        .foregroundColor(.white.opacity(0.7))
                                        .glassCard(cornerRadius: 10)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 30)
                    
                    // 错误提示
                    if let error = settingsVM.configError {
                        HStack {
                            Image(systemName: "exclamationmark.circle.fill")
                            Text(error)
                        }
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding()
                        .glassCard(cornerRadius: 10)
                        .padding(.horizontal, 30)
                    }
                    
                    Spacer(minLength: 50)
                }
            }
        }
    }
    
    /// 网络断开时在顶部显示提示条。
    @ViewBuilder
    private var networkStatusBanner: some View {
        if !networkMonitor.isConnected {
            HStack(spacing: 8) {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 13, weight: .semibold))
                Text("网络连接已断开")
                    .font(.system(size: 13, weight: .medium))
                if appState.isRetryingConfig {
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(.white)
                }
            }
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(Color.red.opacity(0.85))
            )
            .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.3), value: networkMonitor.isConnected)
        }
    }
    
    private func readPasteboardText() -> String? {
        #if os(iOS)
        UIPasteboard.general.string
        #else
        // macOS 下通过 NSPasteboard 读取纯文本。
        NSPasteboard.general.string(forType: .string)
        #endif
    }
    
    // MARK: - iOS 悬浮双岛式 TabBar（系统液态玻璃：主胶囊岛 + 独立圆形搜索岛）
    
    #if os(iOS)
    private var floatingLiquidTabBar: some View {
        HStack(spacing: 12) {
            // 主功能岛：首页、直播、个人（胶囊容器，纯图标，弹性自适应填满，左右边缘与上方内容 20pt 严格对齐）
            HStack(spacing: 0) {
                dockTabItem(index: 0, icon: "house.fill")
                dockTabItem(index: 1, icon: "tv.fill")
                dockTabItem(index: 3, icon: "person.crop.circle.fill")
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .frame(height: 60)
            .frame(maxWidth: .infinity)
            .liquidGlassDock(radius: 30)
            
            // 独立搜索岛：等高 60x60 圆形液态玻璃按钮
            standaloneSearchButton
        }
    }
    
    private func dockTabItem(index: Int, icon: String) -> some View {
        let isSelected = selectedTab == index
        
        return Button {
            if selectedTab != index {
                HapticManager.shared.selection()
                withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                    selectedTab = index
                }
            }
        } label: {
            ZStack {
                if isSelected {
                    Capsule()
                        .fill(Color.white.opacity(0.14))
                        .overlay(
                            Capsule()
                                .strokeBorder(
                                    LinearGradient(
                                        colors: [Color.white.opacity(0.32), Color.white.opacity(0.08)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    ),
                                    lineWidth: 0.5
                                )
                        )
                        .matchedGeometryEffect(id: "liquid_tab_highlight", in: tabAnimationNamespace)
                }
                
                Image(systemName: icon)
                    .font(.system(size: 22, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(isSelected ? AppTheme.accent : Color.white.opacity(0.65))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    
    private var standaloneSearchButton: some View {
        let isSelected = selectedTab == 2
        
        return Button {
            if selectedTab != 2 {
                HapticManager.shared.selection()
                withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                    selectedTab = 2
                }
            }
        } label: {
            ZStack {
                if isSelected {
                    Circle()
                        .fill(Color.white.opacity(0.14))
                        .overlay(
                            Circle()
                                .strokeBorder(
                                    LinearGradient(
                                        colors: [Color.white.opacity(0.32), Color.white.opacity(0.08)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    ),
                                    lineWidth: 0.5
                                )
                        )
                        .padding(5)
                }
                
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 22, weight: isSelected ? .bold : .semibold))
                    .foregroundColor(isSelected ? AppTheme.accent : Color.white.opacity(0.85))
            }
            .frame(width: 60, height: 60)
            .liquidGlassDock(radius: 30)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
    
    @Namespace private var tabAnimationNamespace
    #endif
}

