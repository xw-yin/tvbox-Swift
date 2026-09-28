#if os(iOS)
import SwiftUI

// MARK: - Gesture Mode Enum

/// 手势模式枚举 - 表示当前激活的手势类型
enum PlayerGestureMode: Equatable {
    case none
    case seeking(offset: Double)
    case adjustingBrightness(delta: CGFloat)
    case adjustingVolume(delta: CGFloat)
}

// MARK: - PlayerGestureLayer

/// 播放器手势交互层 - 覆盖在播放器上方的透明手势识别层
/// 支持水平滑动快进快退、左侧垂直滑动调节亮度、右侧垂直滑动调节音量、
/// 双击暂停/播放、捏合缩放
struct PlayerGestureLayer: View {
    // MARK: - Callbacks
    let onSeek: (Double) -> Void
    let onTogglePlayPause: () -> Void
    let onToggleControls: () -> Void
    let onZoomChanged: (CGFloat) -> Void
    /// 亮度变化回调（0...1），拖动过程中实时触发。
    var onBrightnessChanged: (CGFloat) -> Void = { _ in }
    /// 音量变化回调（0...1），拖动过程中实时触发。
    var onVolumeChanged: (CGFloat) -> Void = { _ in }

    // MARK: - Properties
    let currentTime: Double
    let duration: Double
    /// 当前播放器音量（0...1），用于手势指示器显示真实值。
    var currentVolume: Double = 0.5

    // MARK: - State
    @State private var gestureMode: PlayerGestureMode = .none
    @State private var zoomScale: CGFloat = 1.0
    @State private var showIndicator = false
    @State private var dragStartX: CGFloat = 0
    /// 双指缩放进行中时，屏蔽单指拖拽手势（两者是同时识别的）。
    @State private var pinchActive = false
    /// 本次拖拽开始时的基准亮度 / 音量：拖动做绝对定位，避免逐帧累积误差。
    @State private var brightnessBase: CGFloat = 0
    @State private var volumeBase: CGFloat = 0
    /// 本次手势中实际应用的值，指示器显示用。
    @State private var liveBrightness: CGFloat = 0
    @State private var liveVolume: CGFloat = 0

    // MARK: - Pure Computation Functions

    /// 根据起始位置和滑动方向确定手势类型
    static func classifyGesture(
        startX: CGFloat,
        containerWidth: CGFloat,
        translation: CGSize,
        threshold: CGFloat = 10
    ) -> PlayerGestureMode {
        let absH = abs(translation.width)
        let absV = abs(translation.height)

        // 水平优先判定（快进快退）
        if absH > absV && absH > threshold {
            // 根据滑动距离动态调整快进幅度，短距离精细，长距离快速
            let normalizedOffset = translation.width / containerWidth
            let offset = Double(normalizedOffset) * 120.0 // 滑满屏幕 = 120秒
            return .seeking(offset: offset)
        }

        // 垂直判定：左半区域 = 亮度，右半区域 = 音量
        if absV > threshold {
            let isLeftHalf = startX < containerWidth / 2
            let delta = -translation.height / 300.0 // 向上为正
            if isLeftHalf {
                return .adjustingBrightness(delta: delta)
            } else {
                return .adjustingVolume(delta: delta)
            }
        }

        return .none
    }

    /// 计算快进快退目标时间（带边界钳制）
    static func computeSeekTarget(
        currentTime: Double,
        offset: Double,
        duration: Double
    ) -> Double {
        let target = currentTime + offset
        return max(0, min(target, duration))
    }

    /// 钳制调节值到 [0, 1] 范围
    static func clampAdjustment(
        currentValue: CGFloat,
        delta: CGFloat
    ) -> CGFloat {
        return max(0.0, min(1.0, currentValue + delta))
    }

    /// 钳制缩放值到 [minZoom, maxZoom] 范围
    static func clampZoom(
        scale: CGFloat,
        minZoom: CGFloat = 1.0,
        maxZoom: CGFloat = 3.0
    ) -> CGFloat {
        return max(minZoom, min(maxZoom, scale))
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { geometry in
            Color.clear
                .contentShape(Rectangle())
                // 注意：同一个 view 上写两个 .gesture() 时后者会替换前者，
                // 必须用 simultaneously(with:) 把拖拽和缩放组合成一个手势。
                .gesture(dragGesture(in: geometry).simultaneously(with: pinchGesture))
                .onTapGesture(count: 2) {
                    HapticManager.shared.lightImpact()
                    onTogglePlayPause()
                }
                .onTapGesture(count: 1) {
                    onToggleControls()
                }
                .overlay { gestureIndicatorOverlay }
        }
    }

    // MARK: - Drag Gesture

    private func dragGesture(in geometry: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: 5)
            .onChanged { value in
                // 双指缩放进行中：忽略单指拖拽，避免缩放时误触发快进。
                guard !pinchActive else { return }
                if gestureMode == .none {
                    dragStartX = value.startLocation.x
                    // 捕获基准值，本次拖拽内做绝对定位。
                    brightnessBase = UIScreen.main.brightness
                    volumeBase = CGFloat(currentVolume)
                    liveBrightness = brightnessBase
                    liveVolume = volumeBase
                    HapticManager.shared.lightImpact()
                }

                let mode = Self.classifyGesture(
                    startX: dragStartX,
                    containerWidth: geometry.size.width,
                    translation: value.translation
                )

                if mode != .none {
                    gestureMode = mode
                    // 亮度 / 音量拖动中实时生效；快进在松手时一次性提交。
                    switch mode {
                    case .adjustingBrightness(let delta):
                        let applied = Self.clampAdjustment(currentValue: brightnessBase, delta: delta)
                        liveBrightness = applied
                        onBrightnessChanged(applied)
                    case .adjustingVolume(let delta):
                        let applied = Self.clampAdjustment(currentValue: volumeBase, delta: delta)
                        liveVolume = applied
                        onVolumeChanged(applied)
                    case .seeking, .none:
                        break
                    }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showIndicator = true
                    }
                }
            }
            .onEnded { _ in
                if !pinchActive {
                    switch gestureMode {
                    case .seeking(let offset):
                        let target = Self.computeSeekTarget(
                            currentTime: currentTime,
                            offset: offset,
                            duration: duration
                        )
                        onSeek(target - currentTime)
                    case .adjustingBrightness, .adjustingVolume, .none:
                        // 亮度 / 音量已在拖动中实时应用，松手无需再处理。
                        break
                    }
                }

                gestureMode = .none
                withAnimation(.easeInOut(duration: 0.2)) {
                    showIndicator = false
                }
            }
    }

    // MARK: - Pinch Gesture

    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                pinchActive = true
                let newScale = Self.clampZoom(scale: value.magnification * zoomScale)
                onZoomChanged(newScale)
                gestureMode = .none
            }
            .onEnded { value in
                zoomScale = Self.clampZoom(scale: value.magnification * zoomScale)
                onZoomChanged(zoomScale)
                pinchActive = false
            }
    }

    // MARK: - Gesture Indicator Overlay

    @ViewBuilder
    private var gestureIndicatorOverlay: some View {
        // gestureMode == .none 时不展示（比如双指缩放），避免出现空胶囊。
        if showIndicator && gestureMode != .none {
            VStack(spacing: 8) {
                indicatorIcon
                indicatorText
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .opacity(showIndicator ? 1 : 0)
            .animation(.easeInOut(duration: 0.2), value: showIndicator)
        }
    }

    @ViewBuilder
    private var indicatorIcon: some View {
        switch gestureMode {
        case .seeking(let offset):
            Image(systemName: offset >= 0 ? "forward.fill" : "backward.fill")
                .font(.title2)
                .foregroundColor(.white)
        case .adjustingBrightness:
            Image(systemName: "sun.max.fill")
                .font(.title2)
                .foregroundColor(.yellow)
        case .adjustingVolume:
            Image(systemName: "speaker.wave.2.fill")
                .font(.title2)
                .foregroundColor(.white)
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private var indicatorText: some View {
        switch gestureMode {
        case .seeking(let offset):
            let target = Self.computeSeekTarget(
                currentTime: currentTime,
                offset: offset,
                duration: duration
            )
            Text(formatTime(target))
                .font(.caption)
                .foregroundColor(.white)
        case .adjustingBrightness:
            // 显示本次手势实际应用的值，而非按 delta 反推。
            Text("\(Int(liveBrightness * 100))%")
                .font(.caption)
                .foregroundColor(.white)
        case .adjustingVolume:
            Text("\(Int(liveVolume * 100))%")
                .font(.caption)
                .foregroundColor(.white)
        case .none:
            EmptyView()
        }
    }

    // MARK: - Helpers

    private func formatTime(_ seconds: Double) -> String {
        let totalSeconds = Int(max(0, seconds))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%02d:%02d", minutes, secs)
        }
    }
}
#endif
