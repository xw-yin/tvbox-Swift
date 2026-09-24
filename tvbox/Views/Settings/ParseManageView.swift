import SwiftUI

/// 解析接口管理：查看配置下发的解析接口，增删用户自定义解析。
struct ParseManageView: View {
    @StateObject private var apiConfig = ApiConfig.shared
    @State private var showAddSheet = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // 配置下发的解析（只读）
                if !apiConfig.parseBeanList.isEmpty {
                    SectionCard(title: "配置解析（\(apiConfig.parseBeanList.count)）") {
                        ForEach(apiConfig.parseBeanList) { parse in
                            parseRow(parse, isCustom: false)
                            if parse.id != apiConfig.parseBeanList.last?.id {
                                Divider().background(Color.white.opacity(0.1))
                            }
                        }
                    }
                }

                // 用户自定义解析
                SectionCard(title: "自定义解析（\(apiConfig.customParses.count)）") {
                    if apiConfig.customParses.isEmpty {
                        Text("暂无自定义解析，点击右上角添加")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.45))
                            .padding(.vertical, 14)
                            .frame(maxWidth: .infinity)
                    } else {
                        ForEach(apiConfig.customParses) { parse in
                            parseRow(parse, isCustom: true)
                            if parse.id != apiConfig.customParses.last?.id {
                                Divider().background(Color.white.opacity(0.1))
                            }
                        }
                    }
                }

                Text("自定义解析排在配置解析之后参与解析链路，\n链路按历史延迟自动优选，无需手动排序。")
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.4))
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
        }
        .background(AppTheme.pageBackground.ignoresSafeArea())
        .navigationTitle("解析接口")
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .hidesFloatingTabBar()
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddParseSheet()
        }
    }

    @ViewBuilder
    private func parseRow(_ parse: ParseBean, isCustom: Bool) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(parse.name.isEmpty ? "未命名" : parse.name)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(parse.type == 1 ? "JSON" : "嗅探")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(parse.type == 1 ? AppTheme.accent : .orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background((parse.type == 1 ? AppTheme.accent : .orange).opacity(0.15))
                        .clipShape(Capsule())
                    if isCustom {
                        Text("自定义")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }
                Text(parse.url)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.45))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if isCustom {
                Button {
                    apiConfig.removeCustomParse(parse)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 14))
                        .foregroundColor(.red.opacity(0.8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 4)
    }
}

/// 新增自定义解析弹窗
struct AddParseSheet: View {
    @StateObject private var apiConfig = ApiConfig.shared
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    @State private var type = 1
    @State private var errorMessage: String?

    private var isValid: Bool {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let u = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !n.isEmpty && (u.hasPrefix("http://") || u.hasPrefix("https://"))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("名称")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.6))
                    TextField("例如：我的解析", text: $name)
                        .textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("接口地址")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.6))
                    TextField("https://…", text: $url)
                        .textFieldStyle(.roundedBorder)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    #if os(iOS)
                        .keyboardType(.URL)
                    #endif
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("类型")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.6))
                    Picker("类型", selection: $type) {
                        Text("JSON 解析").tag(1)
                        Text("网页嗅探").tag(0)
                    }
                    .pickerStyle(.segmented)
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundColor(.red)
                }
                Spacer()
            }
            .padding(20)
            .background(AppTheme.pageBackground.ignoresSafeArea())
            .navigationTitle("添加解析接口")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !n.isEmpty else {
                            errorMessage = "请填写名称"
                            return
                        }
                        guard u.lowercased().hasPrefix("http://") || u.lowercased().hasPrefix("https://") else {
                            errorMessage = "接口地址需以 http:// 或 https:// 开头"
                            return
                        }
                        apiConfig.addCustomParse(name: n, url: u, type: type)
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium])
        #endif
    }
}
