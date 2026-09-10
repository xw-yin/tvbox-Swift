import SwiftUI

/// 设置页 - 对应 Android 版 SettingActivity + ModelSettingFragment
struct SettingsView: View {
    var sourcesOnly = false
    enum ApiInputType {
        case vod
        case live
        
        var title: String {
            switch self {
            case .vod: return "点播接口地址"
            case .live: return "直播接口地址"
            }
        }
        
        var placeholder: String {
            switch self {
            case .vod: return "请输入点播接口地址"
            case .live: return "请输入直播接口地址（可留空跟随点播）"
            }
        }
    }
    
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = SettingsViewModel()
    @StateObject private var apiConfig = ApiConfig.shared
    @EnvironmentObject var appState: AppState
    @State private var showApiInput = false
    @State private var editingApiType: ApiInputType = .vod
    @State private var showAbout = false
    @State private var showingPicker: PickerType = .none
    
    enum PickerType {
        case none
        case vodPlayer
        case livePlayer
        case decode
        case vlcBuffer
        case playTimeStep
    }
    
    var body: some View {
        VStack(spacing: 0) {
            #if os(iOS)
            // 小标题在整行居中，不受两侧按钮宽度影响。
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 38, height: 38)
                        .liquidControl(radius: 19)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("返回")
                
                Spacer()
            }
            .overlay {
                Text(sourcesOnly ? "源管理" : "设置")
                    .font(.headline)
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 64)
                    .frame(maxWidth: .infinity)
                    .accessibilityAddTraits(.isHeader)
                    .allowsHitTesting(false)
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 12)

            #endif

            ScrollView {
                VStack(spacing: 24) {
                    // API 配置
                    SectionCard(title: "数据源") {
                        SettingsRow(
                            icon: "film",
                            title: "点播接口地址",
                            value: viewModel.vodApiUrl.isEmpty ? "未配置" : viewModel.vodApiUrl
                        ) {
                            viewModel.restoreSavedAddresses()
                            editingApiType = .vod
                            showApiInput = true
                        }
                        .disabled(appState.isLoadingConfig)
                        Divider().background(Color.white.opacity(0.1))
                        SettingsRow(
                            icon: "tv",
                            title: "直播接口地址",
                            value: viewModel.liveApiUrl.isEmpty ? "跟随点播接口" : viewModel.liveApiUrl
                        ) {
                            viewModel.restoreSavedAddresses()
                            editingApiType = .live
                            showApiInput = true
                        }
                        Divider().background(Color.white.opacity(0.1))
                        if !apiConfig.sourceBeanList.isEmpty {
                            NavigationLink {
                                SourceSelectView()
                            } label: {
                                SettingsRow(icon: "server.rack", title: "主页数据源", value: apiConfig.homeSourceBean?.name ?? "", action: nil)
                            }
                        }
                    }
                    
                    if sourcesOnly {
                        SectionCard(title: "订阅管理") {
                            SettingsRow(icon: "arrow.clockwise", title: "刷新当前订阅", value: appState.isLoadingConfig ? "加载中…" : "") {
                                Task { await appState.reloadSavedConfig() }
                            }
                            .disabled(appState.isLoadingConfig || viewModel.isLoadingConfig)
                            Text("成功加载后自动保存，下次启动直接使用。点击上方地址可修改订阅、切换历史地址或删除历史记录。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding()
                            if let error = appState.configLoadError {
                                HStack(spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(.red)
                                    Text(error)
                                        .font(.caption)
                                        .foregroundColor(.red)
                                }
                                .padding(12)
                                .glassCard(cornerRadius: 10)
                                .padding(.horizontal, 16)
                                .padding(.bottom, 8)
                            }
                        }
                    }
                    if !sourcesOnly {
                        // 播放设置
                        SectionCard(title: "播放设置") {
                            SettingsRow(icon: "play.rectangle", title: "点播播放器", value: viewModel.vodPlayerEngine.title) {
                                if viewModel.playerEngineOptions.count > 1 {
                                    showingPicker = .vodPlayer
                                }
                            }
                            Divider().background(Color.white.opacity(0.1))
                            SettingsRow(icon: "dot.radiowaves.left.and.right", title: "直播播放器", value: viewModel.livePlayerEngine.title) {
                                if viewModel.playerEngineOptions.count > 1 {
                                    showingPicker = .livePlayer
                                }
                            }
                            Divider().background(Color.white.opacity(0.1))
                            SettingsRow(icon: "cpu", title: "视频解码", value: viewModel.decodeMode.title) {
                                showingPicker = .decode
                            }
                            if PlayerEngine.isVLCAvailable {
                                Divider().background(Color.white.opacity(0.1))
                                SettingsRow(icon: "externaldrive.badge.wifi", title: "VLC缓冲", value: viewModel.vlcBufferMode.title) {
                                    showingPicker = .vlcBuffer
                                }
                            }
                            Divider().background(Color.white.opacity(0.1))
                            SettingsRow(icon: "forward", title: "快进步长", value: "\(viewModel.playTimeStep)秒") {
                                showingPicker = .playTimeStep
                            }
                        }
                    
                        // 功能
                        SectionCard(title: "功能") {
                            NavigationLink {
                                HistoryView()
                            } label: {
                                SettingsRow(icon: "clock", title: "播放历史", value: "", action: nil)
                            }
                            Divider().background(Color.white.opacity(0.1))
                            NavigationLink {
                                FavoritesView()
                            } label: {
                                SettingsRow(icon: "heart", title: "我的收藏", value: "", action: nil)
                            }
                        }
                    
                        // 缓存
                        SectionCard(title: "缓存") {
                            SettingsRow(icon: "trash", title: "清除缓存", value: viewModel.cacheSizeString) {
                                viewModel.clearCache()
                            }
                        }
                    
                        // 关于
                        SectionCard(title: "关于") {
                            SettingsRow(icon: "info.circle", title: "版本", value: AppTheme.versionDescription, action: nil)
                            Divider().background(Color.white.opacity(0.1))
                            SettingsRow(icon: "globe", title: "站点数量", value: "\(apiConfig.sourceBeanList.count)", action: nil)
                            Divider().background(Color.white.opacity(0.1))
                            SettingsRow(icon: "wand.and.stars", title: "解析数量", value: "\(apiConfig.parseBeanList.count)", action: nil)
                            Divider().background(Color.white.opacity(0.1))
                            SettingsRow(icon: "tv", title: "直播分组", value: "\(apiConfig.liveChannelGroupList.count)", action: nil)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
            }
        }
        .background(AppTheme.pageBackground.ignoresSafeArea())
        .navigationTitle(sourcesOnly ? "源管理" : "设置")
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .hidesFloatingTabBar()
        #endif
        .sheet(isPresented: $showApiInput) {
            ApiConfigSheet(
                editingApiType: editingApiType,
                viewModel: viewModel,
                isPresented: $showApiInput
            )
            .environmentObject(appState)
        }
        .overlay(pickerOverlay)
        .onAppear { viewModel.restoreSavedAddresses() }
    }
    
    // MARK: - 选择器 Overlay
    
    @ViewBuilder
    private var pickerOverlay: some View {
        switch showingPicker {
        case .vodPlayer:
            SelectionModal(
                title: "选择点播播放器",
                icon: "play.rectangle.fill",
                items: viewModel.playerEngineOptions,
                selectedItem: viewModel.vodPlayerEngine,
                itemTitle: { $0.title },
                onSelect: { engine in
                    viewModel.setVodPlayerEngine(engine)
                    showingPicker = .none
                },
                onCancel: { showingPicker = .none }
            )
        case .livePlayer:
            SelectionModal(
                title: "选择直播播放器",
                icon: "dot.radiowaves.left.and.right",
                items: viewModel.playerEngineOptions,
                selectedItem: viewModel.livePlayerEngine,
                itemTitle: { $0.title },
                onSelect: { engine in
                    viewModel.setLivePlayerEngine(engine)
                    showingPicker = .none
                },
                onCancel: { showingPicker = .none }
            )
        case .decode:
            SelectionModal(
                title: "视频解码模式",
                icon: "cpu.fill",
                items: viewModel.decodeModeOptions,
                selectedItem: viewModel.decodeMode,
                itemTitle: { $0.title },
                onSelect: { mode in
                    viewModel.setDecodeMode(mode)
                    showingPicker = .none
                },
                onCancel: { showingPicker = .none }
            )
        case .vlcBuffer:
            SelectionModal(
                title: "VLC 缓冲策略",
                icon: "externaldrive.fill",
                items: viewModel.vlcBufferModeOptions,
                selectedItem: viewModel.vlcBufferMode,
                itemTitle: { $0.title },
                onSelect: { mode in
                    viewModel.setVLCBufferMode(mode)
                    showingPicker = .none
                },
                onCancel: { showingPicker = .none }
            )
        case .playTimeStep:
            SelectionModal(
                title: "快进步长",
                icon: "forward.fill",
                items: viewModel.playTimeStepOptions,
                selectedItem: viewModel.playTimeStep,
                itemTitle: { "\($0) 秒" },
                onSelect: { step in
                    viewModel.setPlayTimeStep(step)
                    showingPicker = .none
                },
                onCancel: { showingPicker = .none }
            )
        case .none:
            EmptyView()
        }
    }
    
    // MARK: - API 输入弹窗

}

// MARK: - API 输入弹窗

struct ApiConfigSheet: View {
    let editingApiType: SettingsView.ApiInputType
    @ObservedObject var viewModel: SettingsViewModel
    @EnvironmentObject var appState: AppState
    @Binding var isPresented: Bool
    
    @FocusState private var isFieldFocused: Bool
    
    private var currentBinding: Binding<String> {
        switch editingApiType {
        case .vod: return $viewModel.vodApiUrl
        case .live: return $viewModel.liveApiUrl
        }
    }
    
    private var isSubmitDisabled: Bool {
        viewModel.isLoadingConfig || currentBinding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // 1. 类型说明与兼容提示卡片
                    guideHeaderCard
                    
                    // 2. 液态玻璃输入区域卡片
                    inputCard
                    
                    // 3. 错误提示（若有）
                    if let error = viewModel.configError {
                        errorCard(error)
                    }
                    
                    // 4. 确认导入主按钮
                    submitButton
                    
                    // 5. 历史记录模块
                    if !viewModel.apiHistory.isEmpty {
                        historyCard
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .background(AppTheme.pageBackground.ignoresSafeArea())
            .navigationTitle(editingApiType.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white.opacity(0.8))
                            .frame(width: 30, height: 30)
                            .liquidControl(radius: 15)
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isLoadingConfig)
                }
            }
            #else
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { isPresented = false }
                        .disabled(viewModel.isLoadingConfig)
                }
            }
            #endif
        }
        .interactiveDismissDisabled(viewModel.isLoadingConfig)
        .overlay(multiRepoSelectionOverlay)
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
    }
    
    // MARK: - 顶部提示卡片
    
    private var guideHeaderCard: some View {
        HStack(spacing: 14) {
            Image(systemName: editingApiType == .vod ? "film.stack.fill" : "tv.and.mediabox.fill")
                .font(.system(size: 24))
                .foregroundColor(AppTheme.accent)
                .frame(width: 44, height: 44)
                .background(
                    Circle().fill(AppTheme.accent.opacity(0.12))
                )
            
            VStack(alignment: .leading, spacing: 4) {
                Text(editingApiType == .vod ? "配置点播数据源" : "配置直播数据源")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                
                Text(editingApiType == .vod 
                     ? "支持 TVBox JSON 订阅、单仓/多仓配置及 XPTV 扩展源" 
                     : "设置独立电视直播源；若留空则自动跟随点播接口中的直播配置")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(2)
            }
            
            Spacer()
        }
        .padding(14)
        .glassCard(cornerRadius: 16)
    }
    
    // MARK: - 输入区域卡片
    
    private var inputCard: some View {
        VStack(spacing: 14) {
            // 输入行
            HStack(spacing: 10) {
                Image(systemName: "link")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(AppTheme.accent)
                
                TextField(editingApiType.placeholder, text: currentBinding)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundColor(.white)
                    .disabled(viewModel.isLoadingConfig)
                    .focused($isFieldFocused)
                    #if os(iOS)
                    .autocapitalization(.none)
                    .autocorrectionDisabled(true)
                    .keyboardType(.URL)
                    #endif
                
                if !currentBinding.wrappedValue.isEmpty {
                    Button {
                        currentBinding.wrappedValue = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.white.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            
            // 底部操作与协议提示栏
            HStack(spacing: 10) {
                Button {
                    if let text = readPasteboardText()?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                        currentBinding.wrappedValue = text
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 12, weight: .medium))
                        Text("粘贴剪贴板")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(.white.opacity(0.9))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .liquidControl(radius: 10)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isLoadingConfig)
                
                if !currentBinding.wrappedValue.isEmpty {
                    Button {
                        currentBinding.wrappedValue = ""
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                            Text("清空")
                                .font(.system(size: 12))
                        }
                        .foregroundColor(.white.opacity(0.6))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .liquidControl(radius: 10)
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isLoadingConfig)
                }
                
                Spacer()
                
                if currentBinding.wrappedValue.hasPrefix("http") {
                    Text(currentBinding.wrappedValue.hasPrefix("https") ? "HTTPS" : "HTTP")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(AppTheme.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(AppTheme.accent.opacity(0.15)))
                }
            }
        }
        .padding(14)
        .glassCard(cornerRadius: 18)
    }
    
    // MARK: - 错误提示卡片
    
    private func errorCard(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15))
                .foregroundColor(.red.opacity(0.9))
            
            Text(error)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
            
            Spacer()
        }
        .padding(12)
        .background(Color.red.opacity(0.12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.red.opacity(0.3), lineWidth: 1)
        )
        .cornerRadius(12)
    }
    
    // MARK: - 确认主按钮
    
    private var submitButton: some View {
        Button {
            isFieldFocused = false
            Task {
                await viewModel.loadConfig()
                if viewModel.configSuccess {
                    appState.applyLoadedConfigState()
                    isPresented = false
                }
            }
        } label: {
            HStack(spacing: 8) {
                if viewModel.isLoadingConfig {
                    ProgressView()
                        .tint(.black)
                    Text("正在解析配置并校验…")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.black)
                } else {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                    Text("确认并载入配置")
                        .font(.system(size: 15, weight: .bold))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                Group {
                    if isSubmitDisabled {
                        Color.white.opacity(0.1)
                    } else {
                        LinearGradient(
                            colors: [AppTheme.accent, AppTheme.accent.opacity(0.85)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    }
                }
            )
            .foregroundColor(isSubmitDisabled ? .white.opacity(0.3) : .black)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(isSubmitDisabled ? 0.05 : 0.25), lineWidth: 1)
            )
            .shadow(color: isSubmitDisabled ? .clear : AppTheme.accent.opacity(0.3), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .disabled(isSubmitDisabled)
    }
    
    // MARK: - 历史记录模块
    
    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 6) {
                    Text("历史记录")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white.opacity(0.7))
                    Text("\(viewModel.apiHistory.count)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(AppTheme.accent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(AppTheme.accent.opacity(0.15)))
                }
                
                Spacer()
                
                Button {
                    viewModel.clearAllApiHistory()
                } label: {
                    Text("清空")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 4)
            
            VStack(spacing: 10) {
                ForEach(viewModel.apiHistory, id: \.self) { url in
                    let isSelected = currentBinding.wrappedValue == url
                    HStack(spacing: 0) {
                        Button {
                            currentBinding.wrappedValue = url
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "clock.arrow.circlepath")
                                    .font(.system(size: 16))
                                    .foregroundColor(isSelected ? AppTheme.accent : .white.opacity(0.45))
                                
                                Text(url)
                                    .font(.system(size: 14))
                                    .foregroundColor(isSelected ? .white : .white.opacity(0.85))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                
                                Spacer()
                            }
                            .padding(.leading, 16)
                            .padding(.trailing, 8)
                            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        
                        Button {
                            viewModel.removeApiHistory(url)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white.opacity(0.4))
                                .frame(width: 40, height: 52)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 6)
                    }
                    .glassCard(cornerRadius: 14)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(isSelected ? AppTheme.accent.opacity(0.45) : Color.clear, lineWidth: 1)
                    )
                }
            }
        }
    }
    
    // MARK: - 多仓候选 Overlay
    
    @ViewBuilder
    private var multiRepoSelectionOverlay: some View {
        if let pending = viewModel.pendingMultiRepoSelection {
            SelectionModal(
                title: "选择\(pending.target.title)仓库",
                icon: "list.bullet.rectangle.portrait.fill",
                items: pending.options,
                selectedItem: nil,
                itemTitle: { $0.name },
                onSelect: { option in
                    Task {
                        await viewModel.selectPendingMultiRepoOption(option)
                        if viewModel.configSuccess {
                            appState.applyLoadedConfigState()
                            isPresented = false
                        }
                    }
                },
                onCancel: {
                    viewModel.cancelPendingMultiRepoSelection()
                }
            )
        }
    }
    
    private func readPasteboardText() -> String? {
        #if os(iOS)
        UIPasteboard.general.string
        #else
        NSPasteboard.general.string(forType: .string)
        #endif
    }
}

// MARK: - 源选择

struct SourceSelectView: View {
    @ObservedObject private var apiConfig = ApiConfig.shared
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var sourceSearchText = ""
    @State private var showAddPage = false
    
    private var filteredSources: [SourceBean] {
        let sources = apiConfig.sourceBeanList
        if sourceSearchText.isEmpty {
            return sources
        } else {
            return sources.filter { $0.name.localizedCaseInsensitiveContains(sourceSearchText) || $0.api.localizedCaseInsensitiveContains(sourceSearchText) }
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            #if os(iOS)
            // 顶部控制行：左上角返回按钮，右上角添加页面按钮
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 38, height: 38)
                        .liquidControl(radius: 19)
                }
                .buttonStyle(.plain)
                
                Spacer()
                
                Button {
                    showAddPage = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .bold))
                        Text("添加页面")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundColor(AppTheme.accent)
                    .padding(.horizontal, 14)
                    .frame(height: 38)
                    .liquidControl(radius: 19)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 2)
            
            // 原生大标题
            HStack {
                Text("选择数据源")
                    .font(.largeTitle.bold())
                    .foregroundColor(.white)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            #endif
            
            // 搜索栏
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("搜索数据源", text: $sourceSearchText)
                    .textFieldStyle(.plain)
                if !sourceSearchText.isEmpty {
                    Button(action: { sourceSearchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
            .glassCard(cornerRadius: 12)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(filteredSources) { source in
                        Button {
                            apiConfig.setHomeSource(source)
                            appState.currentSourceKey = source.key
                        } label: {
                            HStack(alignment: .center, spacing: 16) {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(spacing: 8) {
                                        Text(source.name)
                                            .font(.system(size: 16, weight: .semibold))
                                            .foregroundColor(source.isSupportedInSwift ? .white : .white.opacity(0.5))
                                        
                                        // 类型标签
                                        Text(source.typeDescription)
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundColor(source.isSupportedInSwift ? .orange : .gray)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 3)
                                            .background(
                                                Capsule().fill(
                                                    source.isSupportedInSwift ? AppTheme.accent.opacity(0.2) : Color.gray.opacity(0.2)
                                                )
                                            )
                                        
                                        if apiConfig.isCustomSource(key: source.key) {
                                            Text("自定义")
                                                .font(.system(size: 10, weight: .bold))
                                                .foregroundColor(Color.cyan)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 3)
                                                .background(Capsule().fill(Color.cyan.opacity(0.18)))
                                        }
                                        
                                        if !source.isSupportedInSwift {
                                            Text("暂不支持")
                                                .font(.system(size: 10, weight: .medium))
                                                .foregroundColor(.red.opacity(0.8))
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 3)
                                                .background(Capsule().fill(Color.red.opacity(0.15)))
                                        }
                                    }
                                    
                                    Text(source.api)
                                        .font(.system(size: 12))
                                        .foregroundColor(.white.opacity(0.5))
                                        .lineLimit(1)
                                }
                                
                                Spacer()
                                
                                HStack(spacing: 12) {
                                    if apiConfig.isCustomSource(key: source.key) {
                                        Button {
                                            withAnimation {
                                                apiConfig.removeCustomSource(key: source.key)
                                                if appState.currentSourceKey == source.key {
                                                    appState.currentSourceKey = apiConfig.homeSourceBean?.key ?? ""
                                                }
                                            }
                                        } label: {
                                            Image(systemName: "trash")
                                                .font(.system(size: 13))
                                                .foregroundColor(.red.opacity(0.8))
                                                .frame(width: 32, height: 32)
                                                .background(Circle().fill(Color.red.opacity(0.12)))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    
                                    if source.isSearchable {
                                        Image(systemName: "magnifyingglass")
                                            .font(.system(size: 14, weight: .medium))
                                            .foregroundColor(.green.opacity(0.8))
                                    }
                                    
                                    if source.key == apiConfig.homeSourceBean?.key {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 20))
                                            .foregroundColor(AppTheme.accent)
                                    } else {
                                        Circle()
                                            .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                                            .frame(width: 20, height: 20)
                                    }
                                }
                            }
                            .padding(16)
                            .glassCard(cornerRadius: 16)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(
                                        source.key == apiConfig.homeSourceBean?.key ? AppTheme.accent.opacity(0.5) : Color.clear,
                                        lineWidth: 1
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(!source.isSupportedInSwift)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
        .background(AppTheme.pageBackground.ignoresSafeArea())
        .navigationTitle("选择数据源")
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .sheet(isPresented: $showAddPage) {
            AddPageSheet()
        }
    }
}

// MARK: - 辅助组件

struct SectionCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.bold)
                .foregroundColor(.white.opacity(0.6))
                .padding(.leading, 8)
            
            VStack(spacing: 0) {
                content()
            }
            .glassCard(cornerRadius: 16)
        }
    }
}

struct SettingsRow: View {
    let icon: String
    let title: String
    let value: String
    let action: (() -> Void)?
    
    var body: some View {
        Group {
            if let action = action {
                Button(action: action) {
                    rowContent
                }
                .buttonStyle(.plain)
            } else {
                rowContent
            }
        }
    }
    
    private var rowContent: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(AppTheme.accent)
                .frame(width: 24)
            
            Text(title)
                .font(.body)
                .foregroundColor(.white.opacity(0.9))
            
            Spacer()
            
            Text(value)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.5))
                .lineLimit(1)
            
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.white.opacity(0.3))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}
