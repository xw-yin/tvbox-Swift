#if os(iOS)
import SwiftUI

struct ProfileView: View {
    @ObservedObject private var config = ApiConfig.shared
    @AppStorage(HawkConfig.API_URL) private var subscription = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 顶部固定大标题（与首页、搜索、直播样式完全统一，无缩放动画）
                HStack(alignment: .center) {
                    Text("个人")
                        .font(.largeTitle.bold())
                        .foregroundColor(.white)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 12)
                .background(AppTheme.pageBackground)

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        HStack(spacing: 14) {
                            NavigationLink { FavoritesView() } label: {
                                shortcut("我的收藏", subtitle: "留住喜欢的影片", icon: "heart", color: .pink)
                            }
                            NavigationLink { HistoryView() } label: {
                                shortcut("播放历史", subtitle: "接着上次看", icon: "clock", color: AppTheme.accent)
                            }
                        }
                        .buttonStyle(.plain)

                        VStack(alignment: .leading, spacing: 12) {
                            Text("内容与偏好").font(.headline).padding(.horizontal, 6)
                            VStack(spacing: 0) {
                                NavigationLink { SettingsView(sourcesOnly: true) } label: {
                                    row("源管理", subtitle: subscription.isEmpty ? "添加你的第一份订阅" : "\(config.sourceBeanList.count) 个站点 · 管理与切换订阅", icon: "server.rack")
                                }
                                Divider().padding(.leading, 64)
                                NavigationLink { SettingsView() } label: {
                                    row("设置", subtitle: "播放器、解码与缓存", icon: "slider.horizontal.3")
                                }
                            }
                            .glassCard(cornerRadius: 26)
                            .buttonStyle(.plain)
                        }
                        Text("TVBox · \(AppTheme.versionDescription)")
                            .font(.footnote).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity).padding(.top, 12)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 88)
                }
            }
            .background(AppTheme.pageBackground.ignoresSafeArea())
            .navigationTitle("个人")
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private func shortcut(_ title: String, subtitle: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: icon).font(.title2).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20).glassCard(cornerRadius: 26)
    }

    private func row(_ title: String, subtitle: String, icon: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon).font(.title3).foregroundStyle(AppTheme.accent).frame(width: 28)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(20).contentShape(Rectangle())
    }
}
#endif
