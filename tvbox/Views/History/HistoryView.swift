import SwiftUI
import SwiftData

/// 历史记录页 - 对应 Android 版 HistoryActivity
struct HistoryView: View {
    /// 按最近播放时间倒序展示历史记录。
    @Query(sort: \VodRecord.updateTime, order: .reverse)
    private var records: [VodRecord]
    /// SwiftData 上下文，用于删除单条记录或清空历史。
    @Environment(\.modelContext) private var modelContext
    
    #if os(iOS)
    /// iOS 网格配置。
    private let columns = [
        GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 12)
    ]
    #else
    /// macOS 网格配置。
    private let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 16)
    ]
    #endif
    
    var body: some View {
        historyContent
    }
    
    @Environment(\.dismiss) private var dismiss
    
    /// 历史记录内容视图（不含 NavigationStack 包裹）。
    /// iOS 下由外层 ProfileView/SettingsView 的 NavigationStack 管理导航；
    /// macOS 下由 ContentView 的 NavigationSplitView detail 区域使用独立 NavigationStack。
    private var historyContent: some View {
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
                
                if !records.isEmpty {
                    Button {
                        Task { @MainActor in
                            CacheStore.shared.clearHistory(context: modelContext)
                        }
                    } label: {
                        Text("清空")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(AppTheme.accent)
                    }
                }
            }
            .overlay {
                Text("播放历史")
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
                if records.isEmpty {
                    emptyState
                        .frame(maxWidth: .infinity, minHeight: 360)
                } else {
                    LazyVGrid(columns: columns, spacing: 16) {
                        // 记录卡片支持跳转详情与右键删除。
                        ForEach(records) { item in
                            NavigationLink(destination: DetailView(video: movieVideo(from: item))) {
                                recordCard(item)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) {
                                    modelContext.delete(item)
                                    do {
                                        try modelContext.save()
                                    } catch {
                                        print("删除历史记录失败: \(error)")
                                    }
                                } label: {
                                    Label("删除记录", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }
            }
        }
        .background(AppTheme.pageBackground.ignoresSafeArea())
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .hidesFloatingTabBar()
        #else
        .navigationTitle("播放历史")
        .toolbar {
            if !records.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { @MainActor in
                            CacheStore.shared.clearHistory(context: modelContext)
                        }
                    } label: {
                        Text("清空")
                            .foregroundColor(AppTheme.accent)
                    }
                }
            }
        }
        #endif
    }
    
    /// 无历史时的占位视图。
    private var emptyState: some View {
        EmptyStateView(
            icon: "clock.arrow.circlepath",
            title: "暂无播放记录",
            message: "您还没有看任何视频，赶快去首页探索吧！"
        )
        .padding(40)
    }
    
    /// 历史卡片。
    /// 除海报和标题外，额外显示播放进度与更新时间，便于快速续播。
    private func recordCard(_ item: VodRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                CachedAsyncImage(url: URL.posterURL(from: item.vodPic)) { image in
                    image.resizable().aspectRatio(2/3, contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(Color.gray.opacity(0.3))
                        .aspectRatio(2/3, contentMode: .fill)
                        .overlay(Image(systemName: "film").foregroundColor(.gray))
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                
                // 播放进度标签
                if !item.playNote.isEmpty {
                    Text(item.playNote)
                        .font(.system(size: 9))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.7))
                        .cornerRadius(4)
                        .padding(4)
                }
            }
            
            Text(item.vodName)
                .font(.caption)
                .foregroundColor(.white)
                .lineLimit(2)
            
            Text(item.updateTime.displayString)
                .font(.system(size: 10))
                .foregroundColor(.gray)
        }
    }
    
    /// 将历史记录转换为详情页的入参模型。
    private func movieVideo(from item: VodRecord) -> Movie.Video {
        Movie.Video(id: item.vodId, name: item.vodName, pic: item.vodPic, sourceKey: item.sourceKey)
    }
}
