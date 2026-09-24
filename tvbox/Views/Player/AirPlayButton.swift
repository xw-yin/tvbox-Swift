#if os(iOS)
import SwiftUI
import AVKit

/// AirPlay 投屏按钮（`AVRoutePickerView` 的 SwiftUI 封装）。
///
/// 仅系统播放器（AVPlayer）支持 AirPlay 投屏，VLC 内核下请勿展示。
/// 无可用投屏设备时系统会自动置灰图标，无需额外处理。
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.activeTintColor = .white
        picker.tintColor = UIColor.white.withAlphaComponent(0.9)
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#endif
