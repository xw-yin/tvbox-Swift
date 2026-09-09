#if os(iOS)
import UIKit

/// 触觉反馈管理器 - 集中管理所有触觉反馈调用
final class HapticManager {
    static let shared = HapticManager()

    private let lightGenerator = UIImpactFeedbackGenerator(style: .light)
    private let mediumGenerator = UIImpactFeedbackGenerator(style: .medium)
    private let selectionGenerator = UISelectionFeedbackGenerator()

    private init() {
        lightGenerator.prepare()
        mediumGenerator.prepare()
        selectionGenerator.prepare()
    }

    /// 轻量级冲击反馈 - 用于手势开始、双击暂停、点选
    func lightImpact() {
        lightGenerator.impactOccurred()
    }

    /// 中等级别冲击反馈 - 用于频道选择、播放按钮、收藏切换
    func mediumImpact() {
        mediumGenerator.impactOccurred()
    }

    /// 选择级别反馈 - 用于标签切换、集数切换
    func selection() {
        selectionGenerator.selectionChanged()
    }
}
#else
import Foundation

/// 触觉反馈管理器 (macOS 空实现兼容)
final class HapticManager {
    static let shared = HapticManager()
    private init() {}
    func lightImpact() {}
    func mediumImpact() {}
    func selection() {}
}
#endif
