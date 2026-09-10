import SwiftUI

/// 添加自定义页面与数据源弹窗
struct AddPageSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var apiConfig = ApiConfig.shared
    
    // 自定义添加表单
    @State private var customName: String = ""
    @State private var customUrl: String = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var successToast: String?
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                #if os(iOS)
                headerBar
                #endif
                
                ScrollView {
                    VStack(spacing: 16) {
                        customAddSection
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
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
    
    // MARK: - 自定义页面输入板块
    
    private var customAddSection: some View {
        VStack(spacing: 16) {
            // 提示说明
            HStack(spacing: 12) {
                Image(systemName: "sparkles.tv")
                    .font(.system(size: 22))
                    .foregroundColor(AppTheme.accent)
                
                VStack(alignment: .leading, spacing: 3) {
                    Text("添加自定义数据源")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                    Text("支持输入 CMS JSON/XML 接口或 Drpy JS 爬虫脚本网址")
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
                
                TextField("如：4K 影视 / 电影", text: $customName)
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
                    Text("接口或脚本地址")
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
    
    // MARK: - 辅助方法
    
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
        
        guard let url = URL(string: trimmedUrl), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            errorMessage = "请输入有效的 http:// 或 https:// 网址"
            return
        }
        
        errorMessage = nil
        HapticManager.shared.mediumImpact()
        
        let trimmedName = customName.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmedName.isEmpty ? "自定义页面" : trimmedName
        
        let lower = trimmedUrl.lowercased()
        let isJs = lower.hasSuffix(".js") || lower.contains(".js?")
        
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
