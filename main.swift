import AppKit
import AVFoundation
import UniformTypeIdentifiers

final class PlayerRenderView: NSView {
    var onURLDropped: ((URL) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func makeBackingLayer() -> CALayer {
        AVPlayerLayer()
    }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: nil) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard
            let items = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
            let url = items.first
        else {
            return false
        }

        onURLDropped?(url)
        return true
    }
}

final class PlayerWindow: NSWindow {
    var eventHandler: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if eventHandler?(event) == true {
            return
        }
        super.keyDown(with: event)
    }
}

final class PlayerWindowController: NSWindowController, NSWindowDelegate {
    private let player = AVPlayer()
    private let renderView = PlayerRenderView(frame: .zero)
    private let overlayLabel = NSTextField(labelWithString: "拖入视频或按 ⌘O 打开")
    private let hintLabel = NSTextField(labelWithString: "Space 播放/暂停  ←/→ 快退快进  ↑/↓ 音量  F 全屏  M 静音")

    private let openButton = NSButton(title: "打开", target: nil, action: nil)
    private let playPauseButton = NSButton(title: "播放", target: nil, action: nil)
    private let muteButton = NSButton(title: "静音", target: nil, action: nil)
    private let progressSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let timeLabel = NSTextField(labelWithString: "00:00 / 00:00")

    private var timeObserver: Any?
    private var rateObservation: NSKeyValueObservation?
    private var statusObservation: NSKeyValueObservation?
    private var keepTimeUpdatesSuspended = false

    init() {
        let window = PlayerWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Low Power Player"
        window.minSize = NSSize(width: 720, height: 420)
        window.center()
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        super.init(window: window)
        setupPlayer()
        setupUI()
        setupObservers()
        bindActions()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
    }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func openDocument() {
        guard let window else { return }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie, .video]

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.load(url: url, autoplay: true)
        }
    }

    func togglePlayPause() {
        switch player.timeControlStatus {
        case .paused:
            player.play()
        default:
            player.pause()
        }
    }

    func seek(by seconds: Double) {
        guard let item = player.currentItem else { return }
        let duration = item.duration.secondsValue
        guard duration > 0 else { return }

        let current = player.currentTime().secondsValue
        let target = min(max(current + seconds, 0), duration)
        let time = CMTime(seconds: target, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func adjustVolume(by delta: Float) {
        let value = min(max(player.volume + delta, 0), 1)
        player.volume = value
        player.isMuted = value == 0
        updateMuteButton()
    }

    func toggleMute() {
        player.isMuted.toggle()
        updateMuteButton()
    }

    func stopForPowerSavingIfNeeded() {
        guard let window else { return }
        if window.isMiniaturized || !window.occlusionState.contains(.visible) {
            player.pause()
        }
    }

    private func setupPlayer() {
        player.automaticallyWaitsToMinimizeStalling = true
        player.volume = 1
        renderView.playerLayer.player = player
        renderView.playerLayer.videoGravity = .resizeAspect
        renderView.playerLayer.needsDisplayOnBoundsChange = false
        renderView.onURLDropped = { [weak self] url in
            self?.load(url: url, autoplay: true)
        }
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)

        renderView.translatesAutoresizingMaskIntoConstraints = false
        overlayLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.translatesAutoresizingMaskIntoConstraints = false

        overlayLabel.font = .systemFont(ofSize: 28, weight: .semibold)
        overlayLabel.textColor = NSColor.white.withAlphaComponent(0.92)
        overlayLabel.alignment = .center
        overlayLabel.lineBreakMode = .byWordWrapping
        overlayLabel.backgroundColor = .clear

        hintLabel.font = .systemFont(ofSize: 12, weight: .medium)
        hintLabel.textColor = NSColor.white.withAlphaComponent(0.72)
        hintLabel.alignment = .center
        hintLabel.backgroundColor = .clear

        openButton.bezelStyle = .rounded
        playPauseButton.bezelStyle = .rounded
        muteButton.bezelStyle = .rounded
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        timeLabel.textColor = .secondaryLabelColor

        progressSlider.isContinuous = false
        progressSlider.controlSize = .small

        let controls = NSStackView(views: [openButton, playPauseButton, progressSlider, timeLabel, muteButton])
        controls.translatesAutoresizingMaskIntoConstraints = false
        controls.orientation = .horizontal
        controls.spacing = 10
        controls.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        controls.alignment = .centerY
        controls.wantsLayer = true
        controls.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
        controls.layer?.cornerRadius = 12

        root.addSubview(renderView)
        root.addSubview(controls)
        renderView.addSubview(overlayLabel)
        renderView.addSubview(hintLabel)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            root.topAnchor.constraint(equalTo: contentView.topAnchor),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            renderView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            renderView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            renderView.topAnchor.constraint(equalTo: root.topAnchor),
            renderView.bottomAnchor.constraint(equalTo: controls.topAnchor, constant: -10),

            controls.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            controls.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            controls.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            controls.heightAnchor.constraint(equalToConstant: 52),

            progressSlider.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
            timeLabel.widthAnchor.constraint(equalToConstant: 108),
            muteButton.widthAnchor.constraint(equalToConstant: 68),
            playPauseButton.widthAnchor.constraint(equalToConstant: 68),
            openButton.widthAnchor.constraint(equalToConstant: 68),

            overlayLabel.centerXAnchor.constraint(equalTo: renderView.centerXAnchor),
            overlayLabel.centerYAnchor.constraint(equalTo: renderView.centerYAnchor, constant: -12),
            overlayLabel.leadingAnchor.constraint(greaterThanOrEqualTo: renderView.leadingAnchor, constant: 20),
            overlayLabel.trailingAnchor.constraint(lessThanOrEqualTo: renderView.trailingAnchor, constant: -20),

            hintLabel.centerXAnchor.constraint(equalTo: renderView.centerXAnchor),
            hintLabel.topAnchor.constraint(equalTo: overlayLabel.bottomAnchor, constant: 10),
            hintLabel.leadingAnchor.constraint(greaterThanOrEqualTo: renderView.leadingAnchor, constant: 20),
            hintLabel.trailingAnchor.constraint(lessThanOrEqualTo: renderView.trailingAnchor, constant: -20)
        ])

        renderView.wantsLayer = true
        renderView.layer?.backgroundColor = NSColor.black.cgColor
    }

    private func bindActions() {
        openButton.target = self
        openButton.action = #selector(openDocumentAction)

        playPauseButton.target = self
        playPauseButton.action = #selector(togglePlayPauseAction)

        muteButton.target = self
        muteButton.action = #selector(toggleMuteAction)

        progressSlider.target = self
        progressSlider.action = #selector(sliderChanged(_:))

        (window as? PlayerWindow)?.eventHandler = { [weak self] event in
            self?.handleKey(event) ?? false
        }
    }

    private func setupObservers() {
        rateObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.updatePlayPauseButton()
            }
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidChangeOcclusionStateNotification(_:)),
            name: NSWindow.didChangeOcclusionStateNotification,
            object: window
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidMiniaturizeNotification(_:)),
            name: NSWindow.didMiniaturizeNotification,
            object: window
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidHide(_:)),
            name: NSApplication.didHideNotification,
            object: NSApp
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemWillSleep(_:)),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )

        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            self?.refreshTimeline()
        }
    }

    private func observeCurrentItem(_ item: AVPlayerItem?) {
        statusObservation = item?.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    self.overlayLabel.isHidden = true
                    self.hintLabel.isHidden = true
                    self.refreshTimeline()
                case .failed:
                    self.overlayLabel.stringValue = item.error?.localizedDescription ?? "无法打开这个视频"
                    self.overlayLabel.isHidden = false
                    self.hintLabel.isHidden = false
                    self.playPauseButton.title = "播放"
                default:
                    break
                }
            }
        }
    }

    private func load(url: URL, autoplay: Bool) {
        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: false]
        )

        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 1
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        item.audioTimePitchAlgorithm = .varispeed

        player.pause()
        player.replaceCurrentItem(with: item)
        observeCurrentItem(item)

        window?.title = url.lastPathComponent
        window?.representedURL = url
        progressSlider.doubleValue = 0
        timeLabel.stringValue = "00:00 / 00:00"
        overlayLabel.stringValue = "正在载入…"
        overlayLabel.isHidden = false
        hintLabel.isHidden = false

        if autoplay {
            player.play()
        }
    }

    private func refreshTimeline() {
        guard !keepTimeUpdatesSuspended else { return }

        let current = player.currentTime().secondsValue
        let duration = player.currentItem?.duration.secondsValue ?? 0

        if duration > 0 {
            progressSlider.doubleValue = min(max(current / duration, 0), 1)
        } else {
            progressSlider.doubleValue = 0
        }

        timeLabel.stringValue = "\(format(seconds: current)) / \(format(seconds: duration))"
    }

    private func updatePlayPauseButton() {
        let isPlaying = player.timeControlStatus != .paused
        playPauseButton.title = isPlaying ? "暂停" : "播放"
    }

    private func updateMuteButton() {
        muteButton.title = player.isMuted || player.volume <= 0.001 ? "取消静音" : "静音"
    }

    private func format(seconds: Double) -> String {
        guard seconds.isFinite, !seconds.isNaN, seconds >= 0 else {
            return "00:00"
        }

        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }

        return String(format: "%02d:%02d", minutes, secs)
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 49:
            togglePlayPause()
            return true
        case 123:
            seek(by: -5)
            return true
        case 124:
            seek(by: 5)
            return true
        case 125:
            adjustVolume(by: -0.05)
            return true
        case 126:
            adjustVolume(by: 0.05)
            return true
        case 3:
            window?.toggleFullScreen(nil)
            return true
        case 46:
            toggleMute()
            return true
        default:
            return false
        }
    }

    @objc private func openDocumentAction() {
        openDocument()
    }

    @objc private func togglePlayPauseAction() {
        togglePlayPause()
    }

    @objc private func toggleMuteAction() {
        toggleMute()
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        guard let item = player.currentItem else { return }
        let duration = item.duration.secondsValue
        guard duration > 0 else { return }

        keepTimeUpdatesSuspended = true
        let target = duration * sender.doubleValue
        let time = CMTime(seconds: target, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                self?.keepTimeUpdatesSuspended = false
                self?.refreshTimeline()
            }
        }
    }

    @objc private func windowDidChangeOcclusionStateNotification(_ notification: Notification) {
        stopForPowerSavingIfNeeded()
    }

    @objc private func windowDidMiniaturizeNotification(_ notification: Notification) {
        player.pause()
    }

    @objc private func systemWillSleep(_ notification: Notification) {
        player.pause()
    }

    @objc private func applicationDidHide(_ notification: Notification) {
        player.pause()
    }
}

private extension CMTime {
    var secondsValue: Double {
        let value = CMTimeGetSeconds(self)
        return value.isFinite && !value.isNaN ? value : 0
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: PlayerWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = PlayerWindowController()
        controller?.show()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @objc func openDocument(_ sender: Any?) {
        controller?.openDocument()
    }

    @objc func togglePlayback(_ sender: Any?) {
        controller?.togglePlayPause()
    }

    @objc func stepForward(_ sender: Any?) {
        controller?.seek(by: 5)
    }

    @objc func stepBackward(_ sender: Any?) {
        controller?.seek(by: -5)
    }

    @objc func toggleMute(_ sender: Any?) {
        controller?.toggleMute()
    }
}

func makeMenu(delegate: AppDelegate) {
    let mainMenu = NSMenu()

    let appItem = NSMenuItem()
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "关于播放器", action: nil, keyEquivalent: "")
    appMenu.addItem(NSMenuItem.separator())
    appMenu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu
    mainMenu.addItem(appItem)

    let fileItem = NSMenuItem()
    let fileMenu = NSMenu(title: "文件")
    let openItem = NSMenuItem(title: "打开…", action: #selector(AppDelegate.openDocument(_:)), keyEquivalent: "o")
    openItem.target = delegate
    fileMenu.addItem(openItem)
    fileItem.submenu = fileMenu
    mainMenu.addItem(fileItem)

    let playbackItem = NSMenuItem()
    let playbackMenu = NSMenu(title: "播放")

    let toggleItem = NSMenuItem(title: "播放/暂停", action: #selector(AppDelegate.togglePlayback(_:)), keyEquivalent: " ")
    toggleItem.target = delegate
    playbackMenu.addItem(toggleItem)

    let backItem = NSMenuItem(title: "快退 5 秒", action: #selector(AppDelegate.stepBackward(_:)), keyEquivalent: "[")
    backItem.target = delegate
    playbackMenu.addItem(backItem)

    let forwardItem = NSMenuItem(title: "快进 5 秒", action: #selector(AppDelegate.stepForward(_:)), keyEquivalent: "]")
    forwardItem.target = delegate
    playbackMenu.addItem(forwardItem)

    let muteItem = NSMenuItem(title: "静音/取消静音", action: #selector(AppDelegate.toggleMute(_:)), keyEquivalent: "m")
    muteItem.target = delegate
    playbackMenu.addItem(muteItem)

    playbackItem.submenu = playbackMenu
    mainMenu.addItem(playbackItem)

    NSApp.mainMenu = mainMenu
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.setActivationPolicy(.regular)
app.delegate = delegate
makeMenu(delegate: delegate)
app.run()
