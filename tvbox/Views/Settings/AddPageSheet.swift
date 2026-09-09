import SwiftUI

/// 添加页面与 XPTV 扩展源弹窗
struct AddPageSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var apiConfig = ApiConfig.shared
    
    enum TabType: String, CaseIterable {
        case custom = "自定义页面"
        case preset = "XPTV 扩展库"
    }
    
    @State private var selectedTab: TabType = .custom
    
    // 自定义添加表单
    @State private var customName: String = ""
    @State private var customUrl: String = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var successToast: String?
    
    // 预设库搜索与筛选
    @State private var presetSearchText: String = ""
    @State private var presetSources: [SourceBean] = []
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                #if os(iOS)
                headerBar
                #endif
                
                tabSelector
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 14)
                
                ScrollView {
                    VStack(spacing: 16) {
                        if selectedTab == .custom {
                            customAddSection
                        } else {
                            presetLibrarySection
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 30)
                }
            }
            .background(AppTheme.pageBackground.ignoresSafeArea())
            .navigationTitle("添加页面")
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            #else
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            #endif
            .onAppear {
                presetSources = XptvPresetSources.loadPresetSources()
            }
            .overlay(alignment: .bottom) {
                if let toast = successToast {
                    Text(toast)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        .overlay(Capsule().strokeBorder(AppTheme.accent.opacity(0.6), lineWidth: 1))
                        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }
    
    // MARK: - 顶部导航行 (iOS)
    
    private var headerBar: some View {
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
        }
        .overlay {
            Text("添加页面")
                .font(.headline)
                .foregroundColor(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }
    
    // MARK: - 标签切换
    
    private var tabSelector: some View {
        HStack(spacing: 8) {
            ForEach(TabType.allCases, id: \.self) { tab in
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        selectedTab = tab
                    }
                } label: {
                    Text(tab.rawValue)
                        .font(.system(size: 14, weight: selectedTab == tab ? .semibold : .medium))
                        .foregroundColor(selectedTab == tab ? .white : .white.opacity(0.6))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .liquidControl(radius: 14, isSelected: selectedTab == tab)
                }
                .buttonStyle(.plain)
            }
        }
    }
    
    // MARK: - 自定义页面输入板块
    
    private var customAddSection: some View {
        VStack(spacing: 16) {
            // 提示说明
            HStack(spacing: 12) {
                Image(systemName: "sparkles.tv")
                    .font(.system(size: 22))
                    .foregroundColor(AppTheme.accent)
                
                VStack(alignment: .leading, spacing: 3) {
                    Text("支持添加 XPTV 扩展与自定义源")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                    Text("可直接输入 XPTV 扩展脚本 (.js) 网址，系统将自动适配为可访问的独立页面")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.6))
                        .lineLimit(2)
                }
                Spacer()
            }
            .padding(14)
            .glassCard(cornerRadius: 16)
            
            // 名称输入
            VStack(alignment: .leading, spacing: 8) {
                Text("页面名称")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.white.opacity(0.7))
                    .padding(.leading, 4)
                
                TextField("如：4K 影视 / 厂长电影", text: $customName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundColor(.white)
                    .padding(14)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            
            // 链接输入
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("扩展脚本 / 接口地址")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.white.opacity(0.7))
                    Spacer()
                    Button {
                        if let text = readPasteboardText()?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                            customUrl = text
                            if customName.isEmpty {
                                autoInferName(from: text)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.on.clipboard")
                            Text("粘贴")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(AppTheme.accent)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 4)
                
                TextField("https://.../source.js 或 JSON 地址", text: $customUrl)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundColor(.white)
                    .padding(14)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .onChange(of: customUrl) { _, newValue in
                        if customName.isEmpty {
                            autoInferName(from: newValue)
                        }
                    }
            }
            
            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
            
            // 添加提交按钮
            Button {
                submitCustomSource()
            } label: {
                HStack(spacing: 8) {
                    if isSubmitting {
                        ProgressView().tint(.black)
                    } else {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 16, weight: .bold))
                        Text("添加到页面列表")
                            .font(.system(size: 15, weight: .bold))
                    }
                }
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(AppTheme.accent)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: AppTheme.accent.opacity(0.3), radius: 8, y: 3)
            }
            .buttonStyle(.plain)
            .disabled(isSubmitting || customUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(customUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1.0)
            .padding(.top, 6)
        }
    }
    
    // MARK: - 预设 XPTV 扩展库板块
    
    private var presetLibrarySection: some View {
        VStack(spacing: 12) {
            // 搜索栏
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.white.opacity(0.5))
                TextField("搜索 72 款预设 XPTV 扩展", text: $presetSearchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundColor(.white)
                if !presetSearchText.isEmpty {
                    Button {
                        presetSearchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
            .glassCard(cornerRadius: 12)
            
            let filtered = filteredPresets
            
            HStack {
                Text("可选 XPTV 扩展 (\(filtered.count))")
                    .font(.caption.weight(.bold))
                    .foregroundColor(.white.opacity(0.6))
                Spacer()
                if !filtered.isEmpty {
                    Button("一键导入未添加") {
                        importAllUnaddedPresets(filtered)
                    }
                    .font(.caption.weight(.medium))
                    .foregroundColor(AppTheme.accent)
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 4)
            .padding(.top, 4)
            
            LazyVStack(spacing: 10) {
                ForEach(filtered) { source in
                    let isAdded = isSourceAdded(source)
                    
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(source.name)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.white)
                                
                                Text("XPTV")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(.orange)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.orange.opacity(0.18)))
                            }
                            
                            Text(source.api)
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.45))
                                .lineLimit(1)
                        }
                        
                        Spacer()
                        
                        Button {
                            if !isAdded {
                                apiConfig.addCustomSource(source, makeDefault: false)
                                triggerToast("已添加「\(source.name)」到页面")
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: isAdded ? "checkmark" : "plus")
                                Text(isAdded ? "已添加" : "添加")
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(isAdded ? .white.opacity(0.5) : AppTheme.accent)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .liquidControl(radius: 12, isSelected: isAdded)
                        }
                        .buttonStyle(.plain)
                        .disabled(isAdded)
                    }
                    .padding(14)
                    .glassCard(cornerRadius: 14)
                }
            }
        }
    }
    
    // MARK: - 辅助方法
    
    private var filteredPresets: [SourceBean] {
        let trimmed = presetSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return presetSources
        }
        return presetSources.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed) ||
            $0.api.localizedCaseInsensitiveContains(trimmed)
        }
    }
    
    private func isSourceAdded(_ source: SourceBean) -> Bool {
        apiConfig.sourceBeanList.contains(where: { $0.key == source.key || $0.api == source.api })
    }
    
    private func autoInferName(from urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed) {
            let last = url.deletingPathExtension().lastPathComponent
            if !last.isEmpty && last != "/" {
                customName = last
            }
        }
    }
    
    private func submitCustomSource() {
        let trimmedUrl = customUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUrl.isEmpty else { return }
        
        let trimmedName = customName.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmedName.isEmpty ? "XPTV 页面" : trimmedName
        
        let lower = trimmedUrl.lowercased()
        let isJs = lower.hasSuffix(".js") || lower.contains(".js?") || lower.contains("xptv")
        
        let newSource = SourceBean(
            key: "custom_\(abs(trimmedUrl.hashValue))",
            name: finalName,
            api: trimmedUrl,
            searchable: 1,
            filterable: 1,
            quickSearch: 1,
            playerType: 0,
            type: isJs ? 3 : 1,
            ext: trimmedUrl
        )
        
        apiConfig.addCustomSource(newSource, makeDefault: true)
        triggerToast("已成功添加「\(finalName)」页面")
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            dismiss()
        }
    }
    
    private func importAllUnaddedPresets(_ sources: [SourceBean]) {
        var count = 0
        for s in sources {
            if !isSourceAdded(s) {
                apiConfig.addCustomSource(s, makeDefault: false)
                count += 1
            }
        }
        triggerToast("成功导入 \(count) 个 XPTV 页面")
    }
    
    private func triggerToast(_ message: String) {
        withAnimation {
            successToast = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation {
                if successToast == message {
                    successToast = nil
                }
            }
        }
    }
    
    private func readPasteboardText() -> String? {
        #if os(iOS)
        return UIPasteboard.general.string
        #elseif os(macOS)
        return NSPasteboard.general.string(forType: .string)
        #else
        return nil
        #endif
    }
}
