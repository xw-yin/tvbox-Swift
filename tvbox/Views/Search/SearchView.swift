import SwiftUI

/// 搜索页 - 对应 Android 版 SearchActivity
struct SearchView: View {
    /// 搜索状态与结果管理。
    @StateObject private var viewModel = SearchViewModel()
    @FocusState private var searchFocused: Bool
    
    #if os(iOS)
    /// iOS 卡片网格参数。
    private let columns = [
        GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 12)
    ]
    #else
    /// macOS 卡片网格参数。
    private let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 16)
    ]
    #endif
    
    var body: some View {
        NavigationStack {
            GeometryReader { viewport in
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Section {
                            searchContent
                                .frame(minHeight: max(240, viewport.size.height))
                        } header: {
                            searchField
                                .padding(.horizontal, 20)
                                .padding(.vertical, 8)
                                .background(AppTheme.pageBackground.opacity(0.92))
                                .zIndex(1)
                        }
                    }
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .background(AppTheme.pageBackground.ignoresSafeArea())
            .navigationTitle("搜索")
            .onChange(of: viewModel.keyword) { _, value in
                if value.isEmpty { viewModel.results = [] }
            }
            .navigationDestination(for: Movie.Video.self) { video in
                DetailView(video: video)
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
    }
    
    private var searchField: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("影片、剧集、关键词", text: $viewModel.keyword)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .onSubmit { submitSearch() }
                .accessibilityLabel("搜索影片")
            if !viewModel.keyword.isEmpty {
                Button {
                    viewModel.keyword = ""
                    viewModel.results = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("清空搜索")
                Button(action: submitSearch) {
                    Image(systemName: "arrow.up.circle.fill")
                        .foregroundStyle(AppTheme.accent)
                        .frame(width: 44, height: 44)
                }
                .disabled(viewModel.isSearching)
                .accessibilityLabel("开始搜索")
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 4)
        .frame(minHeight: 50)
        .liquidControl(radius: 26)
        .buttonStyle(.plain)
    }

    private func submitSearch() {
        searchFocused = false
        Task { await viewModel.search() }
    }

    @ViewBuilder
    private var searchContent: some View {
        if viewModel.isSearching {
            ProgressView("搜索中…").tint(AppTheme.accent)
                .frame(maxWidth: .infinity)
        } else if !viewModel.results.isEmpty {
            searchResults
        } else if viewModel.keyword.isEmpty {
            searchHistorySection
        } else if let error = viewModel.errorMessage {
            ContentUnavailableView {
                Label("未找到结果", systemImage: "magnifyingglass")
            } description: {
                Text(error)
            }
        } else {
            ContentUnavailableView("搜索影片", systemImage: "magnifyingglass", description: Text("输入关键词后，点击键盘搜索或右侧箭头。"))
        }
    }

    // MARK: - 搜索结果
    
    /// 搜索结果网格。
    private var searchResults: some View {
        LazyVGrid(columns: columns, spacing: 16) {
                ForEach(viewModel.results) { video in
                    NavigationLink(value: video) {
                        VodCardView(video: video)
                    }
                    #if os(iOS)
                    .buttonStyle(VodCardPressStyle())
                    #else
                    .buttonStyle(.plain)
                    #endif
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
    }

    // MARK: - 搜索历史
    
    /// 搜索历史区域，支持复用历史关键词与一键清空。
    private var searchHistorySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !viewModel.searchHistory.isEmpty {
                HStack {
                    Text("搜索历史")
                        .font(.headline)
                        .foregroundColor(.white)
                    Spacer()
                    Button {
                        viewModel.clearHistory()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "trash")
                            Text("清空")
                        }
                        .font(.caption)
                        .foregroundColor(.gray)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                
                FlowLayout(spacing: 8) {
                    ForEach(viewModel.searchHistory, id: \.self) { keyword in
                        Button {
                            viewModel.keyword = keyword
                            Task { await viewModel.search() }
                        } label: {
                            Text(keyword)
                                .font(.subheadline)
                                .foregroundColor(.white.opacity(0.8))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(Color.white.opacity(0.1))
                                .cornerRadius(16)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            } else {
                ContentUnavailableView {
                    Label("下一部，想看什么？", systemImage: "magnifyingglass")
                } description: {
                    Text("搜索影片或剧集，结果来自你添加的订阅。")
                }
            }

            Spacer()
        }
    }
}

/// 流式布局
struct FlowLayout: Layout {
    /// 子项间距。
    var spacing: CGFloat = 8
    
    /// 计算整体尺寸。
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrangement(proposal: proposal, subviews: subviews)
        return result.size
    }
    
    /// 按计算结果放置子视图。
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangement(proposal: ProposedViewSize(width: bounds.width, height: bounds.height), subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }
    
    /// 核心排版算法：按最大宽度逐个放置，超宽后自动换行。
    private func arrangement(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxX: CGFloat = 0
        
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            positions.append(CGPoint(x: currentX, y: currentY))
            lineHeight = max(lineHeight, size.height)
            currentX += size.width + spacing
            maxX = max(maxX, currentX)
        }
        
        return (CGSize(width: maxX, height: currentY + lineHeight), positions)
    }
}
