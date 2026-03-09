// swiftc -framework Cocoa -framework AVFoundation -framework AVKit -framework CoreMedia -framework UniformTypeIdentifiers -framework ImageIO main.swift -o avplayer

import Cocoa
import AVFoundation
import AVKit
import CoreMedia
import UniformTypeIdentifiers
import ImageIO

// MARK: - SeekSlider
final class SeekSlider: NSSlider {
    var onBegan: (() -> Void)?
    var onEnded: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onBegan?()
        super.mouseDown(with: event)
        onEnded?()
    }
}

// MARK: - SegmentResourceLoader
final class SegmentResourceLoader: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate {
    let originalURL: URL
    private var session: URLSession!
    private var pendingRequests: [URLSessionTask: AVAssetResourceLoadingRequest] = [:]
    private var contentType: String?
    private var contentLength: Int64 = 0

    init(url: URL) {
        self.originalURL = url
        super.init()

        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        if loadingRequest.dataRequest != nil {
            processDataRequest(loadingRequest)
            return true
        }

        if loadingRequest.contentInformationRequest != nil {
            fillContentInformation(loadingRequest)
            return true
        }

        return false
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        if let task = pendingRequests.first(where: { $0.value == loadingRequest })?.key {
            task.cancel()
            pendingRequests.removeValue(forKey: task)
        }
    }

    private func fillContentInformation(_ loadingRequest: AVAssetResourceLoadingRequest) {
        if contentLength > 0, contentType != nil {
            fillRequest(loadingRequest)
            return
        }

        var request = URLRequest(url: originalURL)
        request.httpMethod = "HEAD"

        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            guard let self = self else { return }

            if let error = error {
                loadingRequest.finishLoading(with: error)
                return
            }

            if let httpResponse = response as? HTTPURLResponse {
                self.updateContentInfo(from: httpResponse)
                DispatchQueue.main.async {
                    self.fillRequest(loadingRequest)
                }
            } else {
                loadingRequest.finishLoading()
            }
        }.resume()
    }

    private func fillRequest(_ request: AVAssetResourceLoadingRequest) {
        if let info = request.contentInformationRequest {
            info.isByteRangeAccessSupported = true
            info.contentType = self.contentType
            info.contentLength = self.contentLength
        }
        request.finishLoading()
    }

    private func processDataRequest(_ loadingRequest: AVAssetResourceLoadingRequest) {
        guard let dataRequest = loadingRequest.dataRequest else { return }

        let offset = dataRequest.currentOffset != 0 ? dataRequest.currentOffset : dataRequest.requestedOffset
        let length = dataRequest.requestedLength
        guard length > 0 else {
            loadingRequest.finishLoading()
            return
        }

        var req = URLRequest(url: originalURL)
        let range = "bytes=\(offset)-\(offset + Int64(length) - 1)"
        req.setValue(range, forHTTPHeaderField: "Range")

        let task = session.dataTask(with: req)
        pendingRequests[task] = loadingRequest
        task.resume()
    }

    private func updateContentInfo(from response: HTTPURLResponse) {
        if let contentRange = response.value(forHTTPHeaderField: "Content-Range"),
           let total = parseTotalLength(fromContentRange: contentRange) {
            contentLength = total
        } else if response.expectedContentLength > 0 {
            contentLength = response.expectedContentLength
        } else if let lenString = response.value(forHTTPHeaderField: "Content-Length"),
                  let len = Int64(lenString) {
            contentLength = len
        }

        if let mimeType = response.mimeType,
           let ut = UTType(mimeType: mimeType) {
            contentType = ut.identifier
        } else if let extType = UTType(filenameExtension: originalURL.pathExtension) {
            contentType = extType.identifier
        } else {
            contentType = UTType.data.identifier
        }
    }

    private func parseTotalLength(fromContentRange contentRange: String) -> Int64? {
        guard let slashIndex = contentRange.lastIndex(of: "/") else { return nil }
        let totalPart = contentRange[contentRange.index(after: slashIndex)...]
        return Int64(totalPart)
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let httpResponse = response as? HTTPURLResponse {
            updateContentInfo(from: httpResponse)

            if let loadingRequest = pendingRequests[dataTask],
               let info = loadingRequest.contentInformationRequest {
                info.isByteRangeAccessSupported = true
                info.contentType = self.contentType
                info.contentLength = self.contentLength
            }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if let loadingRequest = pendingRequests[dataTask] {
            loadingRequest.dataRequest?.respond(with: data)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let loadingRequest = pendingRequests[task] {
            if let error = error {
                loadingRequest.finishLoading(with: error)
            } else {
                loadingRequest.finishLoading()
            }
            pendingRequests.removeValue(forKey: task)
        }
    }
}

// MARK: - AppDelegate
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var window: NSWindow!
    var playerView: AVPlayerView!
    var player: AVPlayer!
    var resourceLoader: SegmentResourceLoader?

    var playlist: [URL] = []
    var currentIndex: Int = 0

    var playlistContainerView: NSView!
    var playlistScrollView: NSScrollView!
    var playlistTableView: NSTableView!
    var playlistContainerConstraints: [NSLayoutConstraint] = []
    var isProgrammaticSelection = false

    var controlsContainerView: NSView!
    var progressSlider: SeekSlider!
    var currentTimeLabel: NSTextField!
    var durationLabel: NSTextField!
    var controlsContainerConstraints: [NSLayoutConstraint] = []

    private var timeObserverToken: Any?
    private var knownDurationSeconds: Double = 0
    private var isScrubbing = false
    private var pendingSeekSeconds: Double?
    private var wasPlayingBeforeScrubbing = false

    private var keyEventMonitor: Any?
    private var mouseEventMonitor: Any?
    private var mouseHideTimer: Timer?
    private let mouseHideDelay: TimeInterval = 2.0
    private var arePlaybackControlsVisible = false

    private var didScheduleInitialFullScreen = false
    private var didAutoEnterFullScreen = false

    init(url: URL) {
        super.init()
        buildPlaylist(initialURL: url)
    }

    deinit {
        removeEventMonitors()
        removeTimeObserver()
    }

    func buildPlaylist(initialURL: URL) {
        if !initialURL.isFileURL {
            self.playlist = [initialURL]
            self.currentIndex = 0
            return
        }

        let targetPath = initialURL.resolvingSymlinksInPath().path
        let directoryURL = initialURL.deletingLastPathComponent()
        let fileManager = FileManager.default

        do {
            let fileURLs = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.nameKey, .contentTypeKey],
                options: .skipsHiddenFiles
            )

            let supportedTypes = AVURLAsset.audiovisualTypes()
            let commonExtensions = [
                "mp4", "mov", "m4v", "avi", "mkv", "ts", "flv", "webm",
                "mp3", "m4a", "aac", "wav", "flac", "aiff", "ogg"
            ]

            let mediaFiles = fileURLs.filter { fileURL in
                let ext = fileURL.pathExtension.lowercased()
                if commonExtensions.contains(ext) { return true }

                if let resourceValues = try? fileURL.resourceValues(forKeys: [.contentTypeKey]),
                   let uti = resourceValues.contentType {
                    return supportedTypes.contains { type in
                        if let supportedType = UTType(type.rawValue) {
                            return uti.conforms(to: supportedType)
                        }
                        return false
                    }
                }
                return false
            }.sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }

            self.playlist = mediaFiles
            self.currentIndex = playlist.firstIndex(where: {
                $0.resolvingSymlinksInPath().path == targetPath
            }) ?? 0
        } catch {
            self.playlist = [initialURL]
            self.currentIndex = 0
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let frame = NSRect(x: 0, y: 0, width: 960, height: 540)
        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.backgroundColor = .black
        window.collectionBehavior = .fullScreenPrimary
        window.acceptsMouseMovedEvents = true
        window.center()
        window.delegate = self

        playerView = AVPlayerView(frame: window.contentView!.bounds)
        playerView.autoresizingMask = [.width, .height]
        playerView.controlsStyle = .none
        playerView.videoGravity = .resizeAspect
        window.contentView?.addSubview(playerView)

        player = AVPlayer()
        playerView.player = player

        setupPlaybackControlsUI()
        setupPlaylistUI()
        setupTimeObserver()
        playVideo(at: currentIndex)

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        setupKeyboardEvents()
        setupMouseAutoHide()
        scheduleInitialFullScreenIfNeeded()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        scheduleInitialFullScreenIfNeeded()
        scheduleMouseHideIfNeeded()
    }

    func applicationDidResignActive(_ notification: Notification) {
        cancelMouseHideAndShowCursor()
        hidePlaybackControls()
    }

    func applicationWillTerminate(_ notification: Notification) {
        cancelMouseHideAndShowCursor()
        removeEventMonitors()
        removeTimeObserver()
    }

    private func scheduleInitialFullScreenIfNeeded() {
        guard !didScheduleInitialFullScreen else { return }
        didScheduleInitialFullScreen = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.attemptInitialFullScreen(remainingRetries: 12)
        }
    }

    private func attemptInitialFullScreen(remainingRetries: Int) {
        guard !didAutoEnterFullScreen else { return }
        guard window != nil else { return }

        if NSApp.isActive, window.isVisible {
            didAutoEnterFullScreen = true
            enterFullScreenIfNeeded()
        } else if remainingRetries > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.attemptInitialFullScreen(remainingRetries: remainingRetries - 1)
            }
        }
    }

    private func enterFullScreenIfNeeded() {
        guard window != nil else { return }
        guard !window.styleMask.contains(.fullScreen) else { return }
        window.toggleFullScreen(nil)
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        ensureOverlayViewsAttachedToOverlayHost()
        scheduleMouseHideIfNeeded()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        ensureOverlayViewsAttachedToOverlayHost()
        scheduleMouseHideIfNeeded()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        scheduleMouseHideIfNeeded()
    }

    func windowDidResignKey(_ notification: Notification) {
        cancelMouseHideAndShowCursor()
        hidePlaybackControls()
    }

    private func playlistHostView() -> NSView {
        guard let playerView = self.playerView else {
            fatalError("playerView has not been initialized")
        }
        let host: NSView = playerView.contentOverlayView ?? playerView
        host.wantsLayer = true
        return host
    }

    private func ensureOverlayViewsAttachedToOverlayHost() {
        ensureControlsAttachedToOverlayHost()
        ensurePlaylistAttachedToOverlayHost()
    }

    // MARK: Playback Controls UI

    private func setupPlaybackControlsUI() {
        controlsContainerView = NSView()
        controlsContainerView.translatesAutoresizingMaskIntoConstraints = false
        controlsContainerView.wantsLayer = true
        controlsContainerView.layer?.backgroundColor = NSColor(white: 0.0, alpha: 0.48).cgColor
        controlsContainerView.layer?.cornerRadius = 8
        controlsContainerView.layer?.borderColor = NSColor(white: 1.0, alpha: 0.08).cgColor
        controlsContainerView.layer?.borderWidth = 1
        controlsContainerView.layer?.zPosition = 900
        controlsContainerView.alphaValue = 0
        controlsContainerView.isHidden = true

        currentTimeLabel = makeTimeLabel(text: "00:00", alignment: .right)
        durationLabel = makeTimeLabel(text: "--:--", alignment: .left)

        progressSlider = SeekSlider(value: 0, minValue: 0, maxValue: 1, target: self, action: #selector(progressSliderChanged(_:)))
        progressSlider.translatesAutoresizingMaskIntoConstraints = false
        progressSlider.isContinuous = true
        progressSlider.controlSize = .small
        progressSlider.onBegan = { [weak self] in
            self?.beginScrubbing()
        }
        progressSlider.onEnded = { [weak self] in
            self?.endScrubbing()
        }

        controlsContainerView.addSubview(currentTimeLabel)
        controlsContainerView.addSubview(progressSlider)
        controlsContainerView.addSubview(durationLabel)

        NSLayoutConstraint.activate([
            currentTimeLabel.leadingAnchor.constraint(equalTo: controlsContainerView.leadingAnchor, constant: 12),
            currentTimeLabel.centerYAnchor.constraint(equalTo: controlsContainerView.centerYAnchor),
            currentTimeLabel.widthAnchor.constraint(equalToConstant: 64),

            durationLabel.trailingAnchor.constraint(equalTo: controlsContainerView.trailingAnchor, constant: -12),
            durationLabel.centerYAnchor.constraint(equalTo: controlsContainerView.centerYAnchor),
            durationLabel.widthAnchor.constraint(equalToConstant: 64),

            progressSlider.leadingAnchor.constraint(equalTo: currentTimeLabel.trailingAnchor, constant: 10),
            progressSlider.trailingAnchor.constraint(equalTo: durationLabel.leadingAnchor, constant: -10),
            progressSlider.centerYAnchor.constraint(equalTo: controlsContainerView.centerYAnchor)
        ])

        ensureControlsAttachedToOverlayHost()
        resetPlaybackControls()
        hidePlaybackControls()
    }

    private func makeTimeLabel(text: String, alignment: NSTextAlignment) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = alignment
        label.textColor = .white
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.backgroundColor = .clear
        label.lineBreakMode = .byClipping
        return label
    }

    private func attachControlsContainer(to host: NSView) {
        NSLayoutConstraint.deactivate(controlsContainerConstraints)
        controlsContainerConstraints.removeAll()

        controlsContainerView.removeFromSuperview()
        host.addSubview(controlsContainerView, positioned: .above, relativeTo: nil)

        controlsContainerConstraints = [
            controlsContainerView.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 16),
            controlsContainerView.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -16),
            controlsContainerView.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -16),
            controlsContainerView.heightAnchor.constraint(equalToConstant: 40)
        ]
        NSLayoutConstraint.activate(controlsContainerConstraints)
        controlsContainerView.alphaValue = arePlaybackControlsVisible ? 1 : 0
        controlsContainerView.isHidden = !arePlaybackControlsVisible
        controlsContainerView.layer?.zPosition = 900
    }

    private func ensureControlsAttachedToOverlayHost() {
        guard controlsContainerView != nil else { return }
        let host = playlistHostView()

        if controlsContainerView.superview !== host || controlsContainerConstraints.isEmpty {
            attachControlsContainer(to: host)
        } else {
            controlsContainerView.layer?.zPosition = 900
        }
    }

    private func showPlaybackControls() {
        guard controlsContainerView != nil else { return }
        ensureControlsAttachedToOverlayHost()
        controlsContainerView.isHidden = false
        controlsContainerView.alphaValue = 1
        arePlaybackControlsVisible = true
    }

    private func hidePlaybackControls() {
        guard controlsContainerView != nil else { return }
        controlsContainerView.alphaValue = 0
        controlsContainerView.isHidden = true
        arePlaybackControlsVisible = false
    }

    @objc private func progressSliderChanged(_ sender: NSSlider) {
        let seconds = max(0, sender.doubleValue)
        pendingSeekSeconds = seconds
        currentTimeLabel.stringValue = formatTime(seconds)

        if !isScrubbing {
            seekToSeconds(seconds)
        }
    }

    private func setupTimeObserver() {
        guard timeObserverToken == nil else { return }

        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            self?.updatePlaybackControls(currentTime: time)
        }
    }

    private func removeTimeObserver() {
        if let token = timeObserverToken, player != nil {
            player.removeTimeObserver(token)
            timeObserverToken = nil
        }
    }

    private func updatePlaybackControls(currentTime: CMTime) {
        guard progressSlider != nil else { return }

        updateKnownDurationIfReady()

        let seconds = finiteSeconds(from: currentTime)
        if !isScrubbing {
            progressSlider.doubleValue = min(seconds, progressSlider.maxValue)
            currentTimeLabel.stringValue = formatTime(seconds)
        }
    }

    private func resetPlaybackControls() {
        knownDurationSeconds = 0
        pendingSeekSeconds = nil
        isScrubbing = false
        wasPlayingBeforeScrubbing = false

        if currentTimeLabel != nil {
            currentTimeLabel.stringValue = "00:00"
        }
        if durationLabel != nil {
            durationLabel.stringValue = "--:--"
        }
        if progressSlider != nil {
            progressSlider.minValue = 0
            progressSlider.maxValue = 1
            progressSlider.doubleValue = 0
        }
    }

    private func updateKnownDurationIfReady() {
        guard let item = player.currentItem else { return }

        let seconds = CMTimeGetSeconds(item.duration)
        guard seconds.isFinite, seconds > 0 else { return }

        if abs(seconds - knownDurationSeconds) > 0.25 {
            applyKnownDuration(seconds)
        }
    }

    private func refreshDurationFromCurrentItem() {
        guard let item = player.currentItem else {
            applyKnownDuration(0)
            return
        }

        let directSeconds = CMTimeGetSeconds(item.duration)
        if directSeconds.isFinite, directSeconds > 0 {
            applyKnownDuration(directSeconds)
            return
        }

        Task { [weak self, weak item] in
            guard let self = self, let item = item else { return }

            do {
                let duration = try await item.asset.load(.duration)
                let seconds = CMTimeGetSeconds(duration)
                guard seconds.isFinite, seconds > 0 else { return }

                await MainActor.run {
                    guard item === self.player.currentItem else { return }
                    self.applyKnownDuration(seconds)
                }
            } catch {
                // 忽略无法获取时长的情况
            }
        }
    }

    private func applyKnownDuration(_ seconds: Double) {
        let normalized = (seconds.isFinite && seconds > 0) ? seconds : 0
        knownDurationSeconds = normalized

        if normalized > 0 {
            progressSlider.maxValue = normalized
            durationLabel.stringValue = formatTime(normalized)
            if !isScrubbing {
                progressSlider.doubleValue = min(progressSlider.doubleValue, normalized)
            }
        } else {
            progressSlider.maxValue = 1
            durationLabel.stringValue = "--:--"
            if !isScrubbing {
                progressSlider.doubleValue = 0
            }
        }
    }

    private func beginScrubbing() {
        guard !isScrubbing else { return }
        showPlaybackControls()
        cancelMouseHideAndShowCursor()
        isScrubbing = true
        wasPlayingBeforeScrubbing = player.rate > 0
        player.pause()
    }

    private func endScrubbing() {
        guard isScrubbing else { return }

        let targetSeconds = pendingSeekSeconds ?? progressSlider.doubleValue
        isScrubbing = false
        pendingSeekSeconds = nil

        seekToSeconds(targetSeconds)

        if wasPlayingBeforeScrubbing {
            player.play()
        }
        wasPlayingBeforeScrubbing = false

        showPlaybackControls()
        scheduleMouseHideIfNeeded()
    }

    // MARK: Playlist UI

    func setupPlaylistUI() {
        playlistContainerView = NSView()
        playlistContainerView.translatesAutoresizingMaskIntoConstraints = false
        playlistContainerView.wantsLayer = true
        playlistContainerView.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.88).cgColor
        playlistContainerView.layer?.borderColor = NSColor(white: 1.0, alpha: 0.08).cgColor
        playlistContainerView.layer?.borderWidth = 1
        playlistContainerView.layer?.zPosition = 999
        playlistContainerView.isHidden = true

        playlistScrollView = NSScrollView()
        playlistScrollView.translatesAutoresizingMaskIntoConstraints = false
        playlistScrollView.drawsBackground = false
        playlistScrollView.hasVerticalScroller = true
        playlistScrollView.hasHorizontalScroller = false
        playlistScrollView.autohidesScrollers = true

        playlistContainerView.addSubview(playlistScrollView)
        NSLayoutConstraint.activate([
            playlistScrollView.leadingAnchor.constraint(equalTo: playlistContainerView.leadingAnchor),
            playlistScrollView.trailingAnchor.constraint(equalTo: playlistContainerView.trailingAnchor),
            playlistScrollView.topAnchor.constraint(equalTo: playlistContainerView.topAnchor),
            playlistScrollView.bottomAnchor.constraint(equalTo: playlistContainerView.bottomAnchor)
        ])

        playlistTableView = NSTableView(frame: NSRect(x: 0, y: 0, width: 300, height: 0))
        playlistTableView.delegate = self
        playlistTableView.dataSource = self
        playlistTableView.headerView = nil
        playlistTableView.backgroundColor = .clear
        playlistTableView.appearance = NSAppearance(named: .darkAqua)
        playlistTableView.selectionHighlightStyle = .none
        playlistTableView.focusRingType = .none
        playlistTableView.intercellSpacing = NSSize(width: 0, height: 2)
        playlistTableView.style = .fullWidth
        playlistTableView.autoresizingMask = [.width]

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("MainColumn"))
        column.title = "Playlist"
        column.width = 280
        column.resizingMask = .autoresizingMask
        playlistTableView.addTableColumn(column)

        playlistScrollView.documentView = playlistTableView
        ensurePlaylistAttachedToOverlayHost()
    }

    private func attachPlaylistContainer(to host: NSView) {
        NSLayoutConstraint.deactivate(playlistContainerConstraints)
        playlistContainerConstraints.removeAll()

        playlistContainerView.removeFromSuperview()
        host.addSubview(playlistContainerView, positioned: .above, relativeTo: nil)

        playlistContainerConstraints = [
            playlistContainerView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            playlistContainerView.topAnchor.constraint(equalTo: host.topAnchor),
            playlistContainerView.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            playlistContainerView.widthAnchor.constraint(equalToConstant: 300)
        ]
        NSLayoutConstraint.activate(playlistContainerConstraints)
        playlistContainerView.layer?.zPosition = 999
    }

    private func ensurePlaylistAttachedToOverlayHost() {
        guard playlistContainerView != nil else { return }
        let host = playlistHostView()

        if playlistContainerView.superview !== host || playlistContainerConstraints.isEmpty {
            attachPlaylistContainer(to: host)
        } else {
            playlistContainerView.layer?.zPosition = 999
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        return playlist.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        return 24.0
    }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("PlaylistCell")

        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier

            let label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingMiddle
            label.usesSingleLineMode = true
            label.backgroundColor = .clear

            cell.textField = label
            cell.addSubview(label)

            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }

        let label = cell.textField!
        label.stringValue = playlist[row].lastPathComponent
        label.font = (row == currentIndex) ? .boldSystemFont(ofSize: 13) : .systemFont(ofSize: 13)
        label.textColor = (row == currentIndex) ? .systemYellow : .white

        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if isProgrammaticSelection { return }

        let selectedRow = playlistTableView.selectedRow
        if selectedRow >= 0, selectedRow < playlist.count, selectedRow != currentIndex {
            playVideo(at: selectedRow)
        }
    }

    func syncPlaylistSelection() {
        guard playlistTableView != nil, !playlist.isEmpty else { return }

        isProgrammaticSelection = true
        playlistTableView.reloadData()
        playlistTableView.selectRowIndexes(IndexSet(integer: currentIndex), byExtendingSelection: false)
        playlistTableView.scrollRowToVisible(currentIndex)
        isProgrammaticSelection = false
    }

    func togglePlaylist() {
        guard playlistContainerView != nil else { return }

        if playlistContainerView.isHidden {
            ensurePlaylistAttachedToOverlayHost()
            playlistContainerView.isHidden = false
            syncPlaylistSelection()
        } else {
            playlistContainerView.isHidden = true
        }
    }

    // MARK: Playback

    func playVideo(at index: Int) {
        guard !playlist.isEmpty else { return }

        currentIndex = ((index % playlist.count) + playlist.count) % playlist.count
        let url = playlist[currentIndex]
        window.title = "[\(currentIndex + 1)/\(playlist.count)] \(url.lastPathComponent)"

        let asset: AVURLAsset

        if let scheme = url.scheme?.lowercased(), scheme.hasPrefix("http") {
            resourceLoader = SegmentResourceLoader(url: url)
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.scheme = "streaming"
            let assetURL = components?.url ?? url
            asset = AVURLAsset(url: assetURL)
            asset.resourceLoader.setDelegate(resourceLoader, queue: .main)
        } else {
            resourceLoader = nil
            asset = AVURLAsset(url: url)
        }

        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)
        resetPlaybackControls()
        refreshDurationFromCurrentItem()
        player.play()

        ensureOverlayViewsAttachedToOverlayHost()
        syncPlaylistSelection()
        scheduleMouseHideIfNeeded()
    }

    func deleteCurrentVideoDirectly() {
        guard !playlist.isEmpty else { return }

        let urlToDelete = playlist[currentIndex]
        guard urlToDelete.isFileURL else {
            let alert = NSAlert()
            alert.messageText = "Delete Failed"
            alert.informativeText = "Remote URL cannot be deleted directly."
            alert.runModal()
            return
        }

        player.pause()

        do {
            try FileManager.default.removeItem(at: urlToDelete)
            NSSound.beep()

            playlist.remove(at: currentIndex)

            if playlist.isEmpty {
                player.replaceCurrentItem(with: nil)
                window.title = "No Media"
                playlistTableView.reloadData()
                resetPlaybackControls()
            } else {
                if currentIndex >= playlist.count {
                    currentIndex = playlist.count - 1
                }
                playVideo(at: currentIndex)
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Delete Failed"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    // MARK: Keyboard / Mouse

    func setupKeyboardEvents() {
        guard keyEventMonitor == nil else { return }

        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }

            let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""

            switch chars {
            case "q":
                NSApp.terminate(nil)
                return nil
            case "f":
                self.window.toggleFullScreen(nil)
                return nil
            case "p":
                self.togglePlaylist()
                return nil
            case "d":
                self.deleteCurrentVideoDirectly()
                return nil
            case "s":
                self.saveSnapshot()
                return nil
            case "i":
                self.showMediaInfo()
                return nil
            case "n":
                self.playVideo(at: self.currentIndex + 1)
                return nil
            case "b":
                self.playVideo(at: self.currentIndex - 1)
                return nil
            case "r":
                self.player.seek(to: .zero)
                self.player.play()
                return nil
            default:
                break
            }

            if self.handleProgressNavigation(chars) {
                return nil
            }

            // Space
            if event.keyCode == 49 {
                self.player.rate == 0 ? self.player.play() : self.player.pause()
                return nil
            }

            // Left / Right
            if event.keyCode == 123 {
                self.seek(by: -10)
                return nil
            }
            if event.keyCode == 124 {
                self.seek(by: 10)
                return nil
            }

            return event
        }
    }

    func setupMouseAutoHide() {
        guard mouseEventMonitor == nil else { return }

        mouseEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .mouseMoved,
            .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged,
            .scrollWheel
        ]) { [weak self] event in
            self?.handleMouseActivity()
            return event
        }

        scheduleMouseHideIfNeeded()
    }

    private func handleMouseActivity() {
        NSCursor.setHiddenUntilMouseMoves(false)
        showPlaybackControls()
        scheduleMouseHideIfNeeded()
    }

    private func canAutoHidePlaybackOverlay() -> Bool {
        guard let window = window else { return false }
        return NSApp.isActive &&
               window.isVisible &&
               window.isKeyWindow &&
               !isScrubbing
    }

    private func canAutoHideCursor() -> Bool {
        guard let window = window else { return false }
        return canAutoHidePlaybackOverlay() && window.styleMask.contains(.fullScreen)
    }

    private func scheduleMouseHideIfNeeded() {
        mouseHideTimer?.invalidate()
        mouseHideTimer = nil

        guard canAutoHidePlaybackOverlay() else {
            NSCursor.setHiddenUntilMouseMoves(false)
            return
        }

        let timer = Timer(timeInterval: mouseHideDelay, repeats: false) { [weak self] _ in
            self?.hideMouseAndControlsIfNeeded()
        }
        mouseHideTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func hideMouseAndControlsIfNeeded() {
        guard canAutoHidePlaybackOverlay() else { return }

        hidePlaybackControls()

        if canAutoHideCursor() {
            NSCursor.setHiddenUntilMouseMoves(true)
        } else {
            NSCursor.setHiddenUntilMouseMoves(false)
        }
    }

    private func cancelMouseHideAndShowCursor() {
        mouseHideTimer?.invalidate()
        mouseHideTimer = nil
        NSCursor.setHiddenUntilMouseMoves(false)
    }

    private func removeEventMonitors() {
        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyEventMonitor = nil
        }
        if let monitor = mouseEventMonitor {
            NSEvent.removeMonitor(monitor)
            mouseEventMonitor = nil
        }
    }

    // MARK: Seek

    private func handleProgressNavigation(_ chars: String) -> Bool {
        guard chars.count == 1,
              let ch = chars.first,
              let digit = ch.wholeNumberValue else {
            return false
        }

        let progress = digit == 0 ? 0.0 : Double(digit) / 10.0
        seekToProgress(progress)
        return true
    }

    func seek(by seconds: Float64) {
        let currentSeconds = CMTimeGetSeconds(player.currentTime())
        let safeCurrent = currentSeconds.isFinite ? currentSeconds : 0
        let targetSeconds = max(0, safeCurrent + seconds)
        seekToSeconds(targetSeconds)
    }

    private func seekToProgress(_ progress: Double) {
        let clamped = min(max(progress, 0.0), 1.0)
        guard let item = player.currentItem else { return }

        let totalSeconds = CMTimeGetSeconds(item.duration)
        if totalSeconds.isFinite, totalSeconds > 0 {
            seekToSeconds(totalSeconds * clamped)
            return
        }

        Task { [weak self, weak item] in
            guard let self = self, let item = item else { return }

            do {
                let duration = try await item.asset.load(.duration)
                let loadedSeconds = CMTimeGetSeconds(duration)
                guard loadedSeconds.isFinite, loadedSeconds > 0 else { return }

                await MainActor.run {
                    self.seekToSeconds(loadedSeconds * clamped)
                }
            } catch {
                // 忽略无法获取时长的情况
            }
        }
    }

    private func seekToSeconds(_ seconds: Double) {
        let clamped: Double
        if knownDurationSeconds > 0 {
            clamped = min(max(0, seconds), knownDurationSeconds)
        } else {
            clamped = max(0, seconds)
        }

        let target = CMTime(seconds: clamped, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)

        if !isScrubbing {
            progressSlider.doubleValue = clamped
            currentTimeLabel.stringValue = formatTime(clamped)
        }
    }

    // MARK: Media Info / Snapshot

    func showMediaInfo() {
        guard let currentItem = player.currentItem else { return }
        let asset = currentItem.asset
        let fileName = playlist.indices.contains(currentIndex)
            ? playlist[currentIndex].lastPathComponent
            : "Unknown"

        Task {
            do {
                let duration = try await asset.load(.duration)
                let tracks = try await asset.load(.tracks)

                var infoAccumulator = "File: \(fileName)\n"
                infoAccumulator += "Duration: \(String(format: "%.2f", CMTimeGetSeconds(duration)))s\n"

                for track in tracks {
                    if track.mediaType == .video {
                        let size = try await track.load(.naturalSize)
                        let fps = try await track.load(.nominalFrameRate)
                        let formatDescriptions = try await track.load(.formatDescriptions)

                        infoAccumulator += "\n[Video Track]\n"
                        infoAccumulator += "Res: \(Int(size.width))x\(Int(size.height))\n"
                        infoAccumulator += "FPS: \(fps)\n"

                        if let desc = formatDescriptions.first {
                            let codec = CMFormatDescriptionGetMediaSubType(desc)
                            infoAccumulator += "Codec: \(fourCCString(codec))\n"
                        }
                    } else if track.mediaType == .audio {
                        let formatDescriptions = try await track.load(.formatDescriptions)

                        infoAccumulator += "\n[Audio Track]\n"
                        if let desc = formatDescriptions.first,
                           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc) {
                            infoAccumulator += "Sample Rate: \(asbd.pointee.mSampleRate) Hz\n"
                            infoAccumulator += "Format: \(fourCCString(asbd.pointee.mFormatID))\n"
                        }
                    }
                }

                let finalInfo = infoAccumulator

                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "Media Information"
                    alert.informativeText = finalInfo
                    alert.runModal()
                }
            } catch {
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "Error"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
    }

    func saveSnapshot() {
        guard let asset = player.currentItem?.asset else { return }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let currentTime = player.currentTime()

        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: currentTime)]) { _, image, _, result, _ in
            if result == .succeeded, let image = image {
                let data = NSMutableData()
                if let dest = CGImageDestinationCreateWithData(
                    data as CFMutableData,
                    UTType.heic.identifier as CFString,
                    1,
                    nil
                ) {
                    CGImageDestinationAddImage(
                        dest,
                        image,
                        [kCGImageDestinationLossyCompressionQuality as String: 0.8] as CFDictionary
                    )

                    if CGImageDestinationFinalize(dest) {
                        let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                            .appendingPathComponent("snapshot_\(Int(Date().timeIntervalSince1970)).heic")

                        try? data.write(to: path)
                        DispatchQueue.main.async {
                            NSSound.beep()
                            print("Saved: \(path.path)")
                        }
                    }
                }
            }
        }
    }

    // MARK: Helpers

    private func fourCCString(_ code: FourCharCode) -> String {
        let n = Int(code)
        let chars = [
            UnicodeScalar((n >> 24) & 255),
            UnicodeScalar((n >> 16) & 255),
            UnicodeScalar((n >> 8) & 255),
            UnicodeScalar(n & 255)
        ]
        .compactMap { $0 }
        .map { String($0) }
        .joined()

        let trimmed = chars.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Unknown" : trimmed
    }

    private func finiteSeconds(from time: CMTime) -> Double {
        let seconds = CMTimeGetSeconds(time)
        return seconds.isFinite ? max(0, seconds) : 0
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }

        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%02d:%02d", minutes, secs)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

// MARK: - Main
let args = CommandLine.arguments
if args.count < 2 {
    print("Usage: avplayer <url_or_file>")
    exit(1)
}

let input = args[1]
let url = input.hasPrefix("http") ? URL(string: input)! : URL(fileURLWithPath: input)

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let delegate = AppDelegate(url: url)
app.delegate = delegate
app.run()
