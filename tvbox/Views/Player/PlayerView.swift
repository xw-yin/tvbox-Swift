import SwiftUI
import AVKit

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 点播只渲染视频，由外层负责控制栏；直播可显式使用系统控制栏。
struct PlatformVideoPlayer: View {
    let player: AVPlayer
    var showsPlaybackControls = false
    
    var body: some View {
        #if os(macOS)
        MacOSPlayerView(player: player)
        #else
        if showsPlaybackControls {
            VideoPlayer(player: player)
        } else {
            IOSVideoSurface(player: player)
        }
        #endif
    }
}

#if os(iOS)
/// AVPlayerLayer 不创建播放、进度或全屏控件，避免与 SwiftUI 控制层重复。
private struct IOSVideoSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> VideoSurfaceView {
        let view = VideoSurfaceView()
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: VideoSurfaceView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
    }

    static func dismantleUIView(_ view: VideoSurfaceView, coordinator: ()) {
        // 仅解除当前画面的绑定，全屏切换继续复用同一播放会话。
        view.playerLayer.player = nil
    }

    final class VideoSurfaceView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
#endif

#if os(macOS)
private struct MacOSPlayerView: NSViewRepresentable {
    let player: AVPlayer
    
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.showsFullScreenToggleButton = false
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }
    
    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
    
    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        nsView.player = nil
    }
}
#endif

/// 系统播放器会话控制器：用于在页面内联与全屏视图间复用同一 AVPlayer，避免重复拉流
@MainActor
final class SystemPlayerSessionController: ObservableObject {
    fileprivate var player: AVPlayer?
    fileprivate var mediaURLString: String?
    
    func setPlayer(_ newPlayer: AVPlayer, urlString: String) {
        if player !== newPlayer {
            player?.pause()
            player?.replaceCurrentItem(with: nil)
        }
        player = newPlayer
        mediaURLString = urlString
    }
    
    func stop() {
        let stoppingPlayer = player
        player?.pause()
        player = nil
        mediaURLString = nil
        // AVPlayer.replaceCurrentItem(with: nil) 在播放网络流时会同步阻塞主线程数秒。
        // 将其移到后台执行，闭包持有 AVPlayer 强引用防止提前 dealloc。
        if let stoppingPlayer {
            DispatchQueue.global(qos: .utility).async {
                stoppingPlayer.replaceCurrentItem(with: nil)
            }
        }
    }
}

/// 视频播放器组件 - 对应 Android 版 PlayFragment
@MainActor
struct PlayerView: View {
    let urlString: String
    var startPosition: Double = 0
    var onProgressChanged: ((Double, Double?) -> Void)? = nil
    var onPlaybackEnded: (() -> Void)? = nil
    var onToggleFullScreen: (() -> Void)? = nil
    var canPlayNext: Bool = false
    var onPlayNext: (() -> Void)? = nil
    var systemController: SystemPlayerSessionController? = nil
    var vlcController: VLCPlayerController? = nil
    @AppStorage(HawkConfig.PLAY_TYPE_VOD) private var vodPlayTypeRaw = -1
    @AppStorage(HawkConfig.PLAY_TYPE) private var legacyPlayTypeRaw = PlayerEngine.system.rawValue
    
    private var selectedEngine: PlayerEngine {
        let defaults = UserDefaults.standard
        let rawValue: Int
        if defaults.object(forKey: HawkConfig.PLAY_TYPE_VOD) != nil {
            rawValue = vodPlayTypeRaw
        } else if defaults.object(forKey: HawkConfig.PLAY_TYPE) != nil {
            rawValue = legacyPlayTypeRaw
        } else {
            rawValue = PlayerEngine.system.rawValue
        }
        return PlayerEngine.fromStoredValue(rawValue)
    }
    
    var body: some View {
        Group {
            switch selectedEngine {
            case .system:
                AVPlayerContentView(
                    urlString: urlString,
                    startPosition: startPosition,
                    onProgressChanged: onProgressChanged,
                    onPlaybackEnded: onPlaybackEnded,
                    onToggleFullScreen: onToggleFullScreen,
                    canPlayNext: canPlayNext,
                    onPlayNext: onPlayNext,
                    sharedController: systemController
                )
            case .vlc:
                VLCVodPlayerView(
                    urlString: urlString,
                    startPosition: startPosition,
                    onProgressChanged: onProgressChanged,
                    onPlaybackEnded: onPlaybackEnded,
                    onToggleFullScreen: onToggleFullScreen,
                    canPlayNext: canPlayNext,
                    onPlayNext: onPlayNext,
                    sharedController: vlcController
                )
            }
        }
        .id(selectedEngine.rawValue)
        .onAppear {
            if selectedEngine != .system {
                systemController?.stop()
            }
            if selectedEngine != .vlc {
                vlcController?.stop()
            }
        }
        .onChange(of: selectedEngine) { _, newValue in
            if newValue != .system {
                systemController?.stop()
            }
            if newValue != .vlc {
                vlcController?.stop()
            }
        }
    }
}

/// 基于系统 AVPlayer 的点播播放器实现
@MainActor
struct AVPlayerContentView: View {
    private static let supportedPlaybackRates: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
    let urlString: String
    var startPosition: Double = 0
    var onProgressChanged: ((Double, Double?) -> Void)? = nil
    var onPlaybackEnded: (() -> Void)? = nil
    var onToggleFullScreen: (() -> Void)? = nil
    var canPlayNext: Bool = false
    var onPlayNext: (() -> Void)? = nil
    var sharedController: SystemPlayerSessionController? = nil
    @AppStorage(HawkConfig.PLAY_SPEED) private var savedPlaybackRate = 1.0
    @AppStorage(HawkConfig.PLAY_TYPE_VOD) private var vodPlayTypeRaw = -1
    @State private var player: AVPlayer?
    @State private var playbackEndObserver: NSObjectProtocol?
    @State private var timeObserverToken: Any?
    
    // UI 状态
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var volume: Double = 1.0
    @State private var rate: Float = 1.0
    @State private var isPreparing = true
    @State private var playbackError: String?
    @State private var showControls = true
    @State private var controlsTimer: Timer?
    @State private var osdIcon: String?
    @State private var osdOpacity: Double = 0
    @State private var osdTimer: Timer?
    @State private var isDraggingProgress = false
    @State private var draggingSeconds: Double = 0
    @State private var playerObservers: [NSKeyValueObservation] = []
    @State private var activeURLString: String = ""
    @State private var hasAttemptedTLSRecovery = false
    @State private var isTLSError = false
    @State private var resourceLoaderDelegate: HLSResourceLoaderDelegate? = nil
    
    @State private var videoZoomScale: CGFloat = 1.0

    var body: some View {
        ZStack {
            Group {
                if let player = player {
                    PlatformVideoPlayer(player: player)
                        #if os(iOS)
                        .scaleEffect(videoZoomScale)
                        #endif
                } else {
                    ZStack {
                        Color.black
                        ProgressView()
                            .tint(.white)
                    }
                }
            }
            #if !os(iOS)
            .onTapGesture(count: 2) {
                onToggleFullScreen?()
            }
            .onTapGesture(count: 1) {
                togglePlayPauseWithOSD()
            }
            #endif

            if isPreparing {
                ProgressView()
                    .tint(.white)
            }
            
            if let error = playbackError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 36))
                        .foregroundColor(.yellow)
                    Text(isTLSError ? "TLS/证书连接失败" : "播放失败")
                        .font(.headline)
                        .foregroundColor(.white)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .padding(.horizontal, 24)
                    
                    HStack(spacing: 12) {
                        Button {
                            setupPlayer(with: activeURLString.isEmpty ? urlString : activeURLString)
                        } label: {
                            Label("重试", systemImage: "arrow.clockwise")
                                .font(.caption.bold())
                                .foregroundColor(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .liquidControl(radius: 14)
                        }
                        
                        Button {
                            vodPlayTypeRaw = PlayerEngine.vlc.rawValue
                        } label: {
                            Label("切换 VLC 播放", systemImage: "play.tv")
                                .font(.caption.bold())
                                .foregroundColor(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .liquidControl(radius: 14)
                        }
                    }
                    .padding(.top, 4)
                }
                .padding(20)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color(hex: "12141A").opacity(0.92))
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.5), radius: 20, y: 8)
                .padding(.horizontal, 24)
            }

            if let osdIcon = osdIcon {
                Image(systemName: osdIcon)
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(22)
                    .liquidGlassDock(radius: 28)
                    .opacity(osdOpacity)
                    .allowsHitTesting(false)
            }
        }
        #if os(iOS)
        .overlay {
            PlayerGestureLayer(
                onSeek: { offset in seek(by: offset) },
                onTogglePlayPause: { togglePlayPauseWithOSD() },
                onToggleControls: { wakeUpControls() },
                onZoomChanged: { scale in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        videoZoomScale = scale
                    }
                },
                currentTime: currentTime,
                duration: duration
            )
        }
        #endif
        .overlay(alignment: .bottom) {
            GeometryReader { proxy in
                if player != nil {
                    playbackControls(containerWidth: proxy.size.width)
                        .opacity(showControls ? 1.0 : 0.0)
                        .allowsHitTesting(showControls)
                        .accessibilityHidden(!showControls)
                        .animation(.easeInOut(duration: 0.3), value: showControls)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
            }
        }
        .overlay {
            SystemPlayerKeyboardCaptureView(
                onLeft: { seek(by: -seekStep) },
                onRight: { seek(by: seekStep) },
                onTogglePlayPause: { togglePlayPause() },
                onToggleFullScreen: { onToggleFullScreen?() },
                onVolumeDown: { wakeUpControls(); adjustVolume(by: -volumeStep) },
                onVolumeUp: { wakeUpControls(); adjustVolume(by: volumeStep) }
            )
            .frame(width: 1, height: 1)
            .opacity(0.01)
            .allowsHitTesting(false)
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(_): wakeUpControls()
            case .ended: break
            }
        }
        .onAppear {
            syncRateFromSettings()
            wakeUpControls()
        }
        .task(id: urlString) {
            syncRateFromSettings()
            hasAttemptedTLSRecovery = false
            isTLSError = false
            let prepared = await PlaybackStreamSanitizer.shared.preparePlayableURL(from: urlString)
            activeURLString = prepared
            setupPlayer(with: prepared)
            wakeUpControls()
        }
        .onDisappear {
            cleanupPlayer(keepSharedPlayer: sharedController != nil)
            controlsTimer?.invalidate()
            osdTimer?.invalidate()
        }
    }
    
    @MainActor
    private func setupPlayer(with overrideURLString: String? = nil) {
        let rawTarget = overrideURLString ?? (activeURLString.isEmpty ? urlString : activeURLString)
        guard let url = Self.sanitizedURL(from: rawTarget) else {
            print("[AVPlayer] URL sanitization failed for: \(rawTarget)")
            return
        }
        let targetURLString = url.absoluteString
        let preferredRate = normalizedSavedPlaybackRate
        rate = preferredRate
        playbackError = nil
        
        if let sharedController,
           sharedController.mediaURLString == targetURLString,
           let sharedPlayer = sharedController.player {
            cleanupPlayer(keepSharedPlayer: true)
            // 新渲染层直接绑定共享 AVPlayer，无需清空媒体或重新 seek。
            player = sharedPlayer
            applyPreferredPlaybackRate(to: sharedPlayer)
            bindPlayerObservers(for: sharedPlayer)
            reportProgress(for: sharedPlayer)
            return
        }
        
        // 清理旧播放器
        cleanupPlayer()
        
        // 使用 AVURLAsset 并设置自定义 HTTP 头与 ResourceLoader
        let asset = AVURLAsset(url: url)
        if url.scheme?.lowercased() == HLSResourceLoaderDelegate.customScheme {
            let loaderDelegate = HLSResourceLoaderDelegate()
            resourceLoaderDelegate = loaderDelegate
            asset.resourceLoader.setDelegate(loaderDelegate, queue: DispatchQueue.global(qos: .userInitiated))
        } else {
            resourceLoaderDelegate = nil
            asset.resourceLoader.setDelegate(nil, queue: nil)
        }
        let playerItem = AVPlayerItem(asset: asset)
        playerItem.preferredForwardBufferDuration = 0
        let newPlayer = AVPlayer(playerItem: playerItem)
        newPlayer.defaultRate = preferredRate
        if let sharedController {
            sharedController.setPlayer(newPlayer, urlString: targetURLString)
        }
        
        player = newPlayer
        bindPlayerObservers(for: newPlayer)
        startPlayback(for: newPlayer)
    }
    
    private func triggerTLSRecovery() {
        Task { @MainActor in
            let source = activeURLString.isEmpty ? urlString : activeURLString
            guard let fallback = await PlaybackStreamSanitizer.shared.forceFallbackSanitization(for: source) else {
                return
            }
            activeURLString = fallback
            setupPlayer(with: fallback)
        }
    }
    
    /// 将原始 URL 字符串转换为合法的 URL，处理未编码的特殊字符。
    private static func sanitizedURL(from urlString: String) -> URL? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed) {
            return url
        }
        // 尝试对整个字符串进行百分号编码（保留已编码部分）
        if let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let url = URL(string: encoded) {
            return url
        }
        return nil
    }
    
    private func bindPlayerObservers(for player: AVPlayer) {
        playerObservers = [
            player.observe(\.timeControlStatus, options: [.new]) { p, _ in
                let status = p.timeControlStatus
                DispatchQueue.main.async { isPlaying = status == .playing }
            },
            player.observe(\.reasonForWaitingToPlay, options: [.new]) { p, _ in
                let reason = p.reasonForWaitingToPlay
                DispatchQueue.main.async { isPreparing = reason != nil }
            },
            player.observe(\.volume, options: [.new]) { p, _ in
                let vol = Double(p.volume)
                DispatchQueue.main.async { volume = vol }
            },
            player.observe(\.rate, options: [.new]) { p, _ in
                let currentRate = p.rate
                guard currentRate > 0 else { return }
                let normalized = Self.normalizedPlaybackRate(from: currentRate)
                DispatchQueue.main.async {
                    rate = normalized
                    if abs(savedPlaybackRate - Double(normalized)) > 0.001 {
                        savedPlaybackRate = Double(normalized)
                    }
                }
            }
        ]
        // 监听 AVPlayerItem 状态，捕获加载失败的具体原因
        if let item = player.currentItem {
            let itemObserver = item.observe(\.status, options: [.new]) { observedItem, _ in
                if observedItem.status == .failed {
                    let error = observedItem.error
                    let errorDesc = error?.localizedDescription ?? "未知错误"
                    let nsError = error as NSError?
                    let code = nsError?.code ?? 0
                    let domain = nsError?.domain ?? ""
                    let isTLS = code == -1200 || code == -1202 || code == -1204 ||
                        domain.contains("SSL") ||
                        errorDesc.localizedCaseInsensitiveContains("SSL") ||
                        errorDesc.localizedCaseInsensitiveContains("TLS") ||
                        errorDesc.localizedCaseInsensitiveContains("certificate") ||
                        errorDesc.localizedCaseInsensitiveContains("证书") ||
                        errorDesc.localizedCaseInsensitiveContains("安全连接")
                    
                    DispatchQueue.main.async {
                        isPreparing = false
                        playbackError = errorDesc
                        isTLSError = isTLS
                        
                        if isTLS && !hasAttemptedTLSRecovery {
                            hasAttemptedTLSRecovery = true
                            triggerTLSRecovery()
                        }
                    }
                } else if observedItem.status == .readyToPlay {
                    DispatchQueue.main.async {
                        playbackError = nil
                        isTLSError = false
                    }
                }
            }
            playerObservers.append(itemObserver)
        }
        observePlaybackProgress(for: player)
        observePlaybackEnd(for: player)
        isPlaying = player.timeControlStatus == .playing
        isPreparing = player.reasonForWaitingToPlay != nil
        volume = Double(player.volume)
        rate = normalizedSavedPlaybackRate
    }
    
    private func detachPlayerObservers() {
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
            timeObserverToken = nil
        }
        if let observer = playbackEndObserver {
            NotificationCenter.default.removeObserver(observer)
            playbackEndObserver = nil
        }
        playerObservers.forEach { $0.invalidate() }
        playerObservers.removeAll()
    }
    
    @MainActor
    private func cleanupPlayer(keepSharedPlayer: Bool = false) {
        let currentPlayer = player
        detachPlayerObservers()
        
        guard let currentPlayer else { return }
        if keepSharedPlayer, sharedController?.player === currentPlayer {
            player = nil
            return
        }
        
        currentPlayer.pause()
        if sharedController?.player === currentPlayer {
            sharedController?.player = nil
            sharedController?.mediaURLString = nil
        }
        player = nil
        // replaceCurrentItem(with: nil) 在播放网络流时会阻塞主线程，移到后台
        DispatchQueue.global(qos: .utility).async {
            currentPlayer.replaceCurrentItem(with: nil)
        }
    }
    
    private func startPlayback(for player: AVPlayer) {
        let target = max(startPosition, 0)
        
        if target > 0 {
            let seekTime = CMTime(seconds: target, preferredTimescale: 600)
            player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                reportProgress(for: player)
                playAtPreferredRate(player)
            }
        } else {
            playAtPreferredRate(player)
        }
    }
    
    private func togglePlayPause() {
        guard let player = player else { return }
        if player.rate == 0 {
            playAtPreferredRate(player)
        } else {
            player.pause()
        }
    }
    
    private func togglePlayPauseWithOSD() {
        togglePlayPause()
        showOSD(icon: isPlaying ? "pause.fill" : "play.fill")
    }
    
    private func wakeUpControls() {
        withAnimation { showControls = true }
        controlsTimer?.invalidate()
        controlsTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { _ in
            withAnimation(.easeOut(duration: 0.5)) {
                showControls = false
            }
        }
    }
    
    private func showOSD(icon: String) {
        osdIcon = icon
        osdOpacity = 1.0
        osdTimer?.invalidate()
        osdTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { _ in
            withAnimation(.easeOut(duration: 0.5)) {
                osdOpacity = 0.0
            }
        }
    }
    
    private func observePlaybackEnd(for player: AVPlayer) {
        guard let item = player.currentItem else { return }
        
        playbackEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            onPlaybackEnded?()
        }
    }
    
    private func observePlaybackProgress(for player: AVPlayer) {
        let interval = CMTime(seconds: 1, preferredTimescale: 2)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { _ in
            reportProgress(for: player)
        }
    }
    
    private func reportProgress(for player: AVPlayer?) {
        guard let player else { return }
        let current = player.currentTime().seconds
        guard current.isFinite, current >= 0 else { return }
        
        if !isDraggingProgress {
            self.currentTime = current
            self.draggingSeconds = current
        }
        
        let rawDuration = player.currentItem?.duration.seconds
        if let rawDuration, rawDuration.isFinite, rawDuration >= 0 {
            self.duration = rawDuration
        }
        onProgressChanged?(current, duration > 0 ? duration : nil)
    }
    
    private var seekStep: Double {
        let saved = UserDefaults.standard.integer(forKey: HawkConfig.PLAY_TIME_STEP)
        return Double(saved > 0 ? saved : 10)
    }

    private var volumeStep: Double { 0.1 }
    
    private var progressUpperBound: Double {
        max(duration, max(currentTime, 1))
    }

    private func playbackControls(containerWidth: CGFloat) -> some View {
        #if os(iOS)
        let controlWidth = containerWidth * 1.0
        #else
        let controlWidth = containerWidth * 0.7
        #endif

        return VStack(spacing: 0) {
            #if os(iOS)
            // iOS: 紧凑单行布局 — 进度条在上，按钮在下紧贴
            // 进度条行
            HStack(spacing: 8) {
                Text(currentTime.durationString)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(1)
                
                Slider(
                    value: Binding(
                        get: { isDraggingProgress ? draggingSeconds : currentTime },
                        set: { 
                            draggingSeconds = $0
                            wakeUpControls()
                        }
                    ),
                    in: 0...progressUpperBound,
                    onEditingChanged: { editing in
                        isDraggingProgress = editing
                        wakeUpControls()
                        if !editing {
                            seek(to: draggingSeconds)
                        }
                    }
                )
                .accentColor(.white)
                .disabled(duration <= 0)
                
                Text(duration.durationString)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)
            
            // 控制按钮行 — 液态玻璃按钮紧凑排列
            HStack(spacing: 0) {
                // 左：倍速
                playbackRateMenu
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .liquidControl(radius: 12)
                
                Spacer()
                
                // 中间：主控按钮群
                HStack(spacing: 16) {
                    Button {
                        wakeUpControls()
                        seek(by: -seekStep)
                        showOSD(icon: "gobackward.\(Int(seekStep))")
                    } label: {
                        Image(systemName: "gobackward.\(Int(seekStep))")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white.opacity(0.9))
                            .frame(width: 36, height: 36)
                            .liquidControl(radius: 18)
                    }
                    .buttonStyle(.plain)
                    
                    Button {
                        wakeUpControls()
                        togglePlayPauseWithOSD()
                    } label: {
                        ZStack {
                            Circle()
                                .fill(.ultraThinMaterial)
                                .frame(width: 44, height: 44)
                                .overlay(
                                    Circle().strokeBorder(
                                        LinearGradient(
                                            colors: [AppTheme.accent.opacity(0.85), AppTheme.accent.opacity(0.35)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        ),
                                        lineWidth: 1.2
                                    )
                                )
                                .shadow(color: AppTheme.accent.opacity(0.35), radius: 8, y: 2)
                            
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(AppTheme.accent)
                        }
                    }
                    .buttonStyle(.plain)
                    
                    Button {
                        wakeUpControls()
                        seek(by: seekStep)
                        showOSD(icon: "goforward.\(Int(seekStep))")
                    } label: {
                        Image(systemName: "goforward.\(Int(seekStep))")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white.opacity(0.9))
                            .frame(width: 36, height: 36)
                            .liquidControl(radius: 18)
                    }
                    .buttonStyle(.plain)

                    if let onPlayNext {
                        Button {
                            guard canPlayNext else { return }
                            wakeUpControls()
                            onPlayNext()
                            showOSD(icon: "forward.end.fill")
                        } label: {
                            Image(systemName: "forward.end.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(canPlayNext ? .white.opacity(0.9) : .white.opacity(0.3))
                                .frame(width: 36, height: 36)
                                .liquidControl(radius: 18)
                        }
                        .buttonStyle(.plain)
                        .disabled(!canPlayNext)
                    }
                }
                
                Spacer()
                
                // 右：全屏
                if let onToggleFullScreen {
                    Button {
                        wakeUpControls()
                        onToggleFullScreen()
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 36, height: 36)
                            .liquidControl(radius: 18)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
            #else
            // macOS: 保持两行布局
            HStack(spacing: 12) {
                Text(currentTime.durationString)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(1)
                    .frame(width: 62, alignment: .leading)
                
                Slider(
                    value: Binding(
                        get: { isDraggingProgress ? draggingSeconds : currentTime },
                        set: { 
                            draggingSeconds = $0
                            wakeUpControls()
                        }
                    ),
                    in: 0...progressUpperBound,
                    onEditingChanged: { editing in
                        isDraggingProgress = editing
                        wakeUpControls()
                        if !editing {
                            seek(to: draggingSeconds)
                        }
                    }
                )
                .accentColor(.white)
                .disabled(duration <= 0)
                
                Text(duration.durationString)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(1)
                    .frame(width: 62, alignment: .trailing)
            }
            .padding(.horizontal, 4)
            
            HStack(spacing: 0) {
                HStack(spacing: 16) {
                    playbackRateMenu
                }
                .frame(width: 150, alignment: .leading)
                
                Spacer()
                
                HStack(spacing: 20) {
                    Button {
                        wakeUpControls()
                        seek(by: -seekStep)
                        showOSD(icon: "gobackward.\(Int(seekStep))")
                    } label: {
                        Image(systemName: "gobackward.\(Int(seekStep))")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white.opacity(0.95))
                            .frame(width: 38, height: 38)
                            .liquidControl(radius: 19)
                    }
                    .buttonStyle(.plain)
                    
                    Button {
                        wakeUpControls()
                        togglePlayPauseWithOSD()
                    } label: {
                        ZStack {
                            Circle()
                                .fill(.ultraThinMaterial)
                                .frame(width: 44, height: 44)
                                .overlay(
                                    Circle().strokeBorder(
                                        LinearGradient(
                                            colors: [AppTheme.accent.opacity(0.85), AppTheme.accent.opacity(0.35)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        ),
                                        lineWidth: 1.2
                                    )
                                )
                                .shadow(color: AppTheme.accent.opacity(0.35), radius: 8, y: 2)
                            
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(AppTheme.accent)
                        }
                    }
                    .buttonStyle(.plain)
                    
                    Button {
                        wakeUpControls()
                        seek(by: seekStep)
                        showOSD(icon: "goforward.\(Int(seekStep))")
                    } label: {
                        Image(systemName: "goforward.\(Int(seekStep))")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white.opacity(0.95))
                            .frame(width: 38, height: 38)
                            .liquidControl(radius: 19)
                    }
                    .buttonStyle(.plain)

                    if let onPlayNext {
                        Button {
                            guard canPlayNext else { return }
                            wakeUpControls()
                            onPlayNext()
                            showOSD(icon: "forward.end.fill")
                        } label: {
                            Image(systemName: "forward.end.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(canPlayNext ? .white.opacity(0.95) : .white.opacity(0.3))
                                .frame(width: 38, height: 38)
                                .liquidControl(radius: 19)
                        }
                        .buttonStyle(.plain)
                        .disabled(!canPlayNext)
                        .opacity(canPlayNext ? 1 : 0.4)
                    }
                }
                
                Spacer()
                
                HStack(spacing: 14) {
                    HStack(spacing: 6) {
                        Button {
                            wakeUpControls()
                            let newVolume = volume > 0 ? 0.0 : 1.0
                            player?.volume = Float(newVolume)
                            showOSD(icon: newVolume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        } label: {
                            Image(systemName: volumeIconName)
                                .font(.system(size: 14, weight: .bold))
                                .frame(width: 20)
                        }
                        .buttonStyle(.plain)

                        Slider(
                            value: Binding(
                                get: { volume },
                                set: {
                                    player?.volume = Float($0)
                                    wakeUpControls()
                                }
                            ),
                            in: 0...1.0
                        )
                        .accentColor(.white.opacity(0.8))
                        .frame(width: 80)
                    }
                    
                    if let onToggleFullScreen {
                        Button {
                            wakeUpControls()
                            onToggleFullScreen()
                        } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: 36, height: 36)
                                .liquidControl(radius: 18)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: 150, alignment: .trailing)
            }
            .padding(.top, 8)
            #endif
        }
        #if os(iOS)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .foregroundColor(.white)
        .liquidGlassDock(radius: 20)
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
        .frame(maxWidth: min(controlWidth, 540))
        #else
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .foregroundColor(.white)
        .liquidGlassDock(radius: 20)
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
        .frame(width: controlWidth)
        #endif
        .environment(\.colorScheme, .dark)
    }

    private var playbackRateMenu: some View {
        Menu {
            ForEach(Self.supportedPlaybackRates, id: \.self) { r in
                Button {
                    wakeUpControls()
                    setPlaybackRate(r)
                    showOSD(icon: "speedometer")
                } label: {
                    HStack {
                        Text("\(String(format: "%.1f", r))x")
                        if r == rate {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text("\(String(format: "%.1f", rate))x")
                Image(systemName: "chevron.up")
                    .font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 12, weight: .bold, design: .monospaced))
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.12))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var volumeIconName: String {
        if volume <= 0 { return "speaker.slash.fill" }
        if volume < 0.5 { return "speaker.wave.1.fill" }
        return "speaker.wave.2.fill"
    }

    private var normalizedSavedPlaybackRate: Float {
        Self.normalizedPlaybackRate(from: Float(savedPlaybackRate))
    }

    private static func normalizedPlaybackRate(from raw: Float) -> Float {
        guard !supportedPlaybackRates.isEmpty else { return 1.0 }
        return supportedPlaybackRates.min(by: { abs($0 - raw) < abs($1 - raw) }) ?? 1.0
    }

    private func syncRateFromSettings() {
        rate = normalizedSavedPlaybackRate
    }

    private func setPlaybackRate(_ value: Float) {
        let normalized = Self.normalizedPlaybackRate(from: value)
        rate = normalized
        savedPlaybackRate = Double(normalized)
        guard let player else { return }
        player.defaultRate = normalized
        if player.rate > 0 {
            player.rate = normalized
        }
    }

    private func applyPreferredPlaybackRate(to player: AVPlayer) {
        let normalized = normalizedSavedPlaybackRate
        rate = normalized
        player.defaultRate = normalized
        if player.rate > 0 {
            player.rate = normalized
        }
    }

    private func playAtPreferredRate(_ player: AVPlayer) {
        let normalized = normalizedSavedPlaybackRate
        rate = normalized
        player.defaultRate = normalized
        player.playImmediately(atRate: normalized)
    }

    private func seek(to seconds: Double) {
        guard let player = player else { return }
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }
    
    private func seek(by offset: Double) {
        guard let player else { return }
        
        let current = player.currentTime().seconds
        guard current.isFinite else { return }
        let wasPlaying = player.rate != 0 || player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        
        var target = max(current + offset, 0)
        if let duration = player.currentItem?.duration.seconds, duration.isFinite {
            target = min(target, duration)
        }
        
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600)) { _ in
            reportProgress(for: player)
            if wasPlaying {
                playAtPreferredRate(player)
            }
        }
    }

    private func adjustVolume(by delta: Double) {
        guard let player else { return }
        let current = Double(player.volume)
        let target = min(max(current + delta, 0), 1)
        player.volume = Float(target)
        showOSD(icon: target <= 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
    }
}

#if os(macOS)
private struct SystemPlayerKeyboardCaptureView: NSViewRepresentable {
    let onLeft: () -> Void
    let onRight: () -> Void
    let onTogglePlayPause: () -> Void
    let onToggleFullScreen: () -> Void
    let onVolumeDown: () -> Void
    let onVolumeUp: () -> Void
    
    func makeNSView(context: Context) -> SystemPlayerKeyCaptureNSView {
        let view = SystemPlayerKeyCaptureNSView(frame: .zero)
        applyCallbacks(to: view)
        DispatchQueue.main.async {
            view.activate()
        }
        return view
    }
    
    func updateNSView(_ nsView: SystemPlayerKeyCaptureNSView, context: Context) {
        applyCallbacks(to: nsView)
        DispatchQueue.main.async {
            nsView.activate()
        }
    }
    
    private func applyCallbacks(to view: SystemPlayerKeyCaptureNSView) {
        view.onLeft = onLeft
        view.onRight = onRight
        view.onTogglePlayPause = onTogglePlayPause
        view.onToggleFullScreen = onToggleFullScreen
        view.onVolumeDown = onVolumeDown
        view.onVolumeUp = onVolumeUp
    }
}

private final class SystemPlayerKeyCaptureNSView: NSView {
    var onLeft: (() -> Void)?
    var onRight: (() -> Void)?
    var onTogglePlayPause: (() -> Void)?
    var onToggleFullScreen: (() -> Void)?
    var onVolumeDown: (() -> Void)?
    var onVolumeUp: (() -> Void)?
    
    override var acceptsFirstResponder: Bool { true }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        activate()
    }
    
    func activate() {
        window?.makeFirstResponder(self)
    }
    
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty == false {
            super.keyDown(with: event)
            return
        }
        
        switch event.keyCode {
        case 123: // left
            onLeft?()
            return
        case 124: // right
            onRight?()
            return
        case 125: // down
            onVolumeDown?()
            return
        case 126: // up
            onVolumeUp?()
            return
        case 49: // space
            onTogglePlayPause?()
            return
        default: break
        }
        
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch key {
        case "k": onTogglePlayPause?()
        case "f": onToggleFullScreen?()
        default: super.keyDown(with: event)
        }
    }
}
#else
private struct SystemPlayerKeyboardCaptureView: UIViewRepresentable {
    let onLeft: () -> Void
    let onRight: () -> Void
    let onTogglePlayPause: () -> Void
    let onToggleFullScreen: () -> Void
    let onVolumeDown: () -> Void
    let onVolumeUp: () -> Void
    
    func makeUIView(context: Context) -> SystemPlayerKeyCaptureUIView {
        let view = SystemPlayerKeyCaptureUIView(frame: .zero)
        applyCallbacks(to: view)
        DispatchQueue.main.async {
            view.activate()
        }
        return view
    }
    
    func updateUIView(_ uiView: SystemPlayerKeyCaptureUIView, context: Context) {
        applyCallbacks(to: uiView)
        DispatchQueue.main.async {
            uiView.activate()
        }
    }
    
    private func applyCallbacks(to view: SystemPlayerKeyCaptureUIView) {
        view.onLeft = onLeft
        view.onRight = onRight
        view.onTogglePlayPause = onTogglePlayPause
        view.onToggleFullScreen = onToggleFullScreen
        view.onVolumeDown = onVolumeDown
        view.onVolumeUp = onVolumeUp
    }
}

private final class SystemPlayerKeyCaptureUIView: UIView {
    var onLeft: (() -> Void)?
    var onRight: (() -> Void)?
    var onTogglePlayPause: (() -> Void)?
    var onToggleFullScreen: (() -> Void)?
    var onVolumeDown: (() -> Void)?
    var onVolumeUp: (() -> Void)?
    
    override var canBecomeFirstResponder: Bool { true }
    
    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(handleLeft)),
            UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(handleRight)),
            UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(handleVolumeDown)),
            UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(handleVolumeUp)),
            UIKeyCommand(input: " ", modifierFlags: [], action: #selector(handleTogglePlayPause)),
            UIKeyCommand(input: "k", modifierFlags: [], action: #selector(handleTogglePlayPause)),
            UIKeyCommand(input: "f", modifierFlags: [], action: #selector(handleToggleFullScreen))
        ]
    }
    
    override func didMoveToWindow() {
        super.didMoveToWindow()
        activate()
    }
    
    func activate() {
        becomeFirstResponder()
    }
    
    @objc private func handleLeft() { onLeft?() }
    @objc private func handleRight() { onRight?() }
    @objc private func handleVolumeDown() { onVolumeDown?() }
    @objc private func handleVolumeUp() { onVolumeUp?() }
    @objc private func handleTogglePlayPause() { onTogglePlayPause?() }
    @objc private func handleToggleFullScreen() { onToggleFullScreen?() }
}
#endif
