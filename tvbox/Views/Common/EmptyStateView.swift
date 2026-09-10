import SwiftUI

/// 通用空状态组件。
/// 在收藏、历史等页面复用，统一空页面视觉风格。
struct EmptyStateView: View {
    /// SF Symbol 图标名。
    let icon: String
    /// 主标题。
    let title: String
    /// 可选说明文字，为空时不渲染副文案区域。
    var message: String? = nil
    
    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(AppTheme.accent.opacity(0.15))
                    .frame(width: 120, height: 120)
                    .overlay(
                        Circle().stroke(AppTheme.accent.opacity(0.3), lineWidth: 1)
                    )
                
                Image(systemName: icon)
                    .font(.system(size: 46, weight: .light))
                    .foregroundStyle(
                        LinearGradient(colors: [.orange, .red.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
            }
            .padding(.bottom, 8)
            
            // 标题强调当前页面状态，例如“暂无收藏”“暂无播放记录”。
            Text(title)
                .font(.title3.bold())
                .foregroundColor(.white.opacity(0.9))
                .tracking(1)
            
            // 副文案用于提供下一步引导，不参与核心逻辑判断。
            if let message = message {
                Text(message)
                    .font(.callout)
                    .foregroundColor(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
        .padding(40)
        .glassCard(cornerRadius: 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 统一规范的空状态与失败状态视图 (iOS 27 设计系统)

struct UnifiedEmptyStateView<Actions: View>: View {
    let icon: String
    let title: String
    let message: String
    var extraInfo: String? = nil
    var iconColor: Color = AppTheme.accent
    var bottomSpacerHeight: CGFloat = 50
    @ViewBuilder var actions: () -> Actions
    
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            
            Image(systemName: icon)
                .font(.system(size: 52))
                .foregroundColor(iconColor)
            
            Text(title)
                .font(.title2.bold())
                .foregroundColor(.white)
            
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
                .lineLimit(4)
            
            if let extra = extraInfo {
                Text(extra)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            HStack(spacing: 14) {
                actions()
            }
            .padding(.top, 6)
            
            Spacer()
            if bottomSpacerHeight > 0 {
                Spacer().frame(height: bottomSpacerHeight)
            }
        }
        .frame(maxWidth: .infinity)
        .containerRelativeFrame(.vertical)
    }
}

/// 标准主操作胶囊按钮（高度 44pt，主题色背景）
struct EmptyPrimaryButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 20)
            .frame(height: 44)
            .background(AppTheme.accent, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// 标准次操作液态玻璃胶囊按钮（高度 44pt，液态高透毛玻璃）
struct EmptySecondaryButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 20)
            .frame(height: 44)
            .liquidControl(radius: 22)
        }
        .buttonStyle(.plain)
    }
}

/// 标准主操作导航链接（高度 44pt，主题色背景）
struct EmptyPrimaryLink<Destination: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let destination: () -> Destination
    
    var body: some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 20)
            .frame(height: 44)
            .background(AppTheme.accent, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// 标准次操作导航链接（高度 44pt，液态高透毛玻璃）
struct EmptySecondaryLink<Destination: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let destination: () -> Destination
    
    var body: some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 20)
            .frame(height: 44)
            .liquidControl(radius: 22)
        }
        .buttonStyle(.plain)
    }
}

