// main.swift — macOS 15 Media Player
// All requirements from spec implemented in one file.
//
// Build:
//   swiftc -swift-version 6 main.swift -o player \
//     -framework AppKit -framework AVFoundation -framework AVKit \
//     -framework CoreImage -framework ImageIO \
//     -framework UniformTypeIdentifiers -framework CoreMedia
//
// Run:
//   ./player /path/to/video.mp4
//   ./player https://example.com/stream.m3u8

import AppKit
import AVFoundation
import AVKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import CoreMedia

// MARK: - Supported extensions (req 14)

private let kMediaExtensions: Set<String> = [
    "mp4", "m4v", "mov", "avi", "mkv", "wmv", "flv", "webm",
    "mpg", "mpeg", "m2v", "ts",  "mts", "m2ts", "3gp", "3g2",
    "mp3", "m4a", "aac", "wav",  "aiff","flac", "ogg", "opus",
    "hevc","vob", "ogv", "asf",  "rm",  "rmvb"
]

// MARK: - PlaylistItem

struct PlaylistItem: Sendable {
    let url: URL
    var displayName: String { url.lastPathComponent }
    var isLocal: Bool       { url.isFileURL }
}

// MARK: - RemoteResourceLoader  (req 21-24)
// Intercepts requests for our custom scheme, issues real HTTP/S requests
// with Range headers, and fills AVAssetResourceLoadingRequest responses.

final class RemoteResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {

    static let httpsScheme = "mediaplayer-https"
    static let httpScheme  = "mediaplayer-http"

    private let session = URLSession(configuration: .default)
    private var tasks   = [ObjectIdentifier: URLSessionDataTask]()
    private let lock    = NSLock()

    /// Rewrites an http(s) URL to use our custom scheme so AVFoundation
    /// routes loading through this delegate instead of handling it natively.
    static func customURL(for url: URL) -> URL? {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        switch c.scheme?.lowercased() {
        case "https": c.scheme = httpsScheme
        case "http":  c.scheme = httpScheme
        default:      return nil
        }
        return c.url
    }

    // MARK: AVAssetResourceLoaderDelegate

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource r: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = r.request.url,
              var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        switch c.scheme {
        case Self.httpsScheme: c.scheme = "https"
        case Self.httpScheme:  c.scheme = "http"
        default: return false
        }
        guard let realURL = c.url else { return false }

        var req = URLRequest(url: realURL)
        // Byte-range support (req 23)
        if let dr = r.dataRequest {
            if dr.requestsAllDataToEndOfResource {
                req.setValue("bytes=\(dr.requestedOffset)-", forHTTPHeaderField: "Range")
            } else {
                let end = dr.requestedOffset + Int64(dr.requestedLength) - 1
                req.setValue("bytes=\(dr.requestedOffset)-\(end)", forHTTPHeaderField: "Range")
            }
        }

        let key = ObjectIdentifier(r)
        let task = session.dataTask(with: req) { [weak self] data, response, error in
            guard let self else { return }
            defer { self.lock.lock(); self.tasks.removeValue(forKey: key); self.lock.unlock() }
            if let error { r.finishLoading(with: error); return }
            // Content metadata (req 22)
            if let http = response as? HTTPURLResponse,
               let ci   = r.contentInformationRequest {
                let rawMIME = http.value(forHTTPHeaderField: "Content-Type")?
                    .components(separatedBy: ";").first?
                    .trimmingCharacters(in: .whitespaces) ?? "video/mp4"
                ci.contentType                = UTType(mimeType: rawMIME)?.identifier ?? rawMIME
                ci.contentLength              = http.expectedContentLength
                ci.isByteRangeAccessSupported = true
            }
            if let data { r.dataRequest?.respond(with: data) }
            r.finishLoading()
        }
        lock.withLock { tasks[key] = task }
        task.resume()
        return true
    }

    // Cancellable requests (req 24)
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        didCancel r: AVAssetResourceLoadingRequest) {
        let key = ObjectIdentifier(r)
        lock.withLock { tasks[key]?.cancel(); tasks.removeValue(forKey: key) }
    }
}

// MARK: - PlayerWindow

/// Custom window so we can intercept key events before AVPlayerView
/// consumes them (e.g. Space for play/pause).
final class PlayerWindow: NSWindow {
    override var canBecomeKey:  Bool { true }
    override var canBecomeMain: Bool { true }

    // keyDown is intercepted via a local event monitor in the controller.
    // We keep this override as a fallback for events that reach the window.
    override func keyDown(with event: NSEvent) {
        // Handled by local monitor; if it falls through, eat it silently.
    }
}

// MARK: - PlayerWindowController  (req 2, 5-9, 17-20, 25-62)

@MainActor
final class PlayerWindowController: NSWindowController,
                                     NSWindowDelegate,
                                     NSTableViewDataSource,
                                     NSTableViewDelegate {

    // ── Player ────────────────────────────────────────────────────────────
    private let player        = AVPlayer()
    private var playerView    : AVPlayerView!
    private var remoteLoader  : RemoteResourceLoader?
    private var endObs        : Any?
    private var errObs        : Any?

    // ── Playlist ──────────────────────────────────────────────────────────
    private var playlist      : [PlaylistItem] = []
    private var currentIndex  : Int = 0
    private var suppressSelectionChange = false

    // ── Playlist UI ───────────────────────────────────────────────────────
    private var playlistPanel : NSScrollView!
    private var playlistTable : NSTableView!
    private var panelWidth    : NSLayoutConstraint!
    private var isPlaylistVisible = false

    // ── Cursor (req 56-59) ────────────────────────────────────────────────
    private var cursorTimer   : Timer?
    private var cursorHidden  = false

    // ── Event monitors ────────────────────────────────────────────────────
    private var keyMonitor    : Any?
    private var mouseMonitor  : Any?

    // ── One-time fullscreen on first activation (req 9) ───────────────────
    private var didAutoFullscreen = false

    // MARK: init

    init(inputURL: URL) {
        let (items, startIdx) = inputURL.isFileURL
            ? Self.buildLocalPlaylist(from: inputURL)
            : ([PlaylistItem(url: inputURL)], 0)

        let win = PlayerWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
            styleMask:   [.titled, .closable, .miniaturizable,
                          .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        win.backgroundColor = .black
        win.center()
        win.title = "Media Player"

        super.init(window: win)
        win.delegate = self

        playlist     = items
        currentIndex = startIdx

        buildUI()
        installEventMonitors()
        loadCurrentItem()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: UI Construction

    private func buildUI() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.cgColor

        // ── AVPlayerView – floating controls satisfy req 8 ──
        playerView = AVPlayerView()
        playerView.player = player
        playerView.controlsStyle = .floating
        playerView.showsFullScreenToggleButton = true
        playerView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(playerView)

        // ── Playlist sidebar (req 25-31) ──
        playlistPanel = NSScrollView()
        playlistPanel.hasVerticalScroller = true
        playlistPanel.borderType = .noBorder
        playlistPanel.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1.0)
        playlistPanel.translatesAutoresizingMaskIntoConstraints = false
        playlistPanel.isHidden = true
        content.addSubview(playlistPanel)

        playlistTable = NSTableView()
        playlistTable.backgroundColor = .clear
        playlistTable.headerView = nil
        playlistTable.rowHeight = 30
        playlistTable.intercellSpacing = NSSize(width: 0, height: 1)
        playlistTable.dataSource = self
        playlistTable.delegate   = self
        playlistTable.selectionHighlightStyle = .regular
        let col = NSTableColumn(identifier: .init("name"))
        col.isEditable = false
        playlistTable.addTableColumn(col)
        playlistPanel.documentView = playlistTable

        // ── Constraints ──
        // panelWidth = 0 when hidden, 240 when visible
        panelWidth = playlistPanel.widthAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: content.topAnchor),
            playerView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            playerView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: playlistPanel.leadingAnchor),

            playlistPanel.topAnchor.constraint(equalTo: content.topAnchor),
            playlistPanel.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            playlistPanel.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            panelWidth,
        ])
    }

    // MARK: Event Monitors

    private func installEventMonitors() {
        // Keyboard (req 60) – intercept before AVPlayerView consumes Space etc.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let consumed = MainActor.assumeIsolated { self.dispatchKey(event) }
            return consumed ? nil : event
        }

        // Mouse movement – cursor auto-hide (req 56-57)
        mouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel]
        ) { [weak self] event in
            MainActor.assumeIsolated { self?.onMouseActivity() }
            return event
        }
    }

    // MARK: Playlist Building (req 12-16)

    private static func buildLocalPlaylist(from url: URL) -> ([PlaylistItem], Int) {
        let dir = url.deletingLastPathComponent()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentTypeKey],
            options: [.skipsHiddenFiles]          // req 13
        ) else { return ([PlaylistItem(url: url)], 0) }

        // req 14: extensions or audiovisual content type
        let items: [PlaylistItem] = entries
            .filter { fu in
                let ext = fu.pathExtension.lowercased()
                if kMediaExtensions.contains(ext) { return true }
                if let t = try? fu.resourceValues(forKeys: [.contentTypeKey]).contentType {
                    return t.conforms(to: .audiovisualContent)
                }
                return false
            }
            .sorted {                              // req 15: localized ordering
                $0.lastPathComponent
                  .localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
            .map { PlaylistItem(url: $0) }

        if items.isEmpty { return ([PlaylistItem(url: url)], 0) }
        let idx = items.firstIndex(where: {
            $0.url.standardized == url.standardized
        }) ?? 0                                    // req 16
        return (items, idx)
    }

    // MARK: Playback (req 17-20)

    private func loadCurrentItem() {
        // Clear previous observers
        endObs.map { NotificationCenter.default.removeObserver($0) }
        errObs.map { NotificationCenter.default.removeObserver($0) }
        endObs = nil; errObs = nil

        guard !playlist.isEmpty else {             // req 20
            player.replaceCurrentItem(with: nil)
            window?.title = "No Media"
            if isPlaylistVisible { playlistTable.reloadData() }
            return
        }

        updateWindowTitle()                        // req 19

        let item  = playlist[currentIndex]
        let asset : AVURLAsset

        if item.isLocal {
            remoteLoader = nil
            asset = AVURLAsset(url: item.url)
        } else {                                   // req 10-11, 21-24
            let loader = RemoteResourceLoader()
            remoteLoader = loader
            if let cu = RemoteResourceLoader.customURL(for: item.url) {
                asset = AVURLAsset(url: cu)
                asset.resourceLoader.setDelegate(loader,
                                                  queue: .global(qos: .userInitiated))
            } else {
                asset = AVURLAsset(url: item.url)
            }
        }

        let pi = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: pi)        // req 18
        player.play()                              // req 17

        // Advance to next on end (req 36-37)
        endObs = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: pi, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.playNext() }
        }

        // Log errors
        errObs = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: pi, queue: .main
        ) { notification in
            if let err = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error {
                print("Playback error: \(err.localizedDescription)")
            }
        }

        refreshPlaylistHighlight()
    }

    private func updateWindowTitle() {
        guard !playlist.isEmpty else { window?.title = "No Media"; return }
        let it = playlist[currentIndex]
        window?.title = "[\(currentIndex + 1)/\(playlist.count)]  \(it.displayName)"
    }

    private func refreshPlaylistHighlight() {
        guard isPlaylistVisible else { return }
        suppressSelectionChange = true
        playlistTable.reloadData()
        let row = currentIndex
        guard row < playlistTable.numberOfRows else {
            suppressSelectionChange = false
            return
        }
        playlistTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        playlistTable.scrollRowToVisible(row)   // req 31
        suppressSelectionChange = false
    }

    // MARK: Transport Controls (req 32-39)

    func playPause() {                              // req 32
        if player.timeControlStatus == .playing { player.pause() }
        else { player.play() }
    }

    func restart() {                                // req 33
        player.seek(to: .zero)
        player.play()
    }

    func seekBackward() {                           // req 34
        let t = CMTimeSubtract(player.currentTime(),
                               CMTimeMakeWithSeconds(10, preferredTimescale: 600))
        player.seek(to: CMTimeMaximum(t, .zero))
    }

    func seekForward() {                            // req 35
        guard let ci = player.currentItem else { return }
        let t   = CMTimeAdd(player.currentTime(),
                            CMTimeMakeWithSeconds(10, preferredTimescale: 600))
        let dur = ci.duration.seconds
        player.seek(to: dur.isFinite
            ? CMTimeMinimum(t, CMTimeMakeWithSeconds(dur, preferredTimescale: 600))
            : t)
    }

    func playNext() {                               // req 36-37
        currentIndex = (currentIndex < playlist.count - 1) ? currentIndex + 1 : 0
        loadCurrentItem()
    }

    func playPrevious() {                           // req 38-39
        if currentIndex > 0 { currentIndex -= 1 }
        loadCurrentItem()
    }

    // MARK: Playlist Toggle (req 25-31)

    func togglePlaylist() {
        isPlaylistVisible.toggle()
        if isPlaylistVisible {
            panelWidth.constant  = 240
            playlistPanel.isHidden = false
            suppressSelectionChange = true
            playlistTable.reloadData()
            let row = currentIndex
            if row < playlistTable.numberOfRows {
                playlistTable.selectRowIndexes(IndexSet(integer: row),
                                               byExtendingSelection: false)
                playlistTable.scrollRowToVisible(row)
            }
            suppressSelectionChange = false
            stopCursorTimer()        // req 58
            showCursor()
        } else {
            panelWidth.constant    = 0
            playlistPanel.isHidden = true
            if window?.styleMask.contains(.fullScreen) == true {
                resetCursorTimer() // resume hiding when back to hidden playlist
            }
        }
    }

    // MARK: Delete (req 49-55)

    func deleteCurrentFile() {
        guard !playlist.isEmpty else { return }
        let item = playlist[currentIndex]
        guard item.isLocal else {                  // req 50-51
            showInfo("Cannot delete remote media items.")
            return
        }

        player.pause()
        player.replaceCurrentItem(with: nil)       // req 52a

        do {
            try FileManager.default.removeItem(at: item.url)
        } catch {                                  // req 55
            showError("Failed to delete file:\n\(error.localizedDescription)")
            loadCurrentItem()
            return
        }

        let deletedIdx = currentIndex
        playlist.remove(at: deletedIdx)            // req 52b

        if playlist.isEmpty {                      // req 54
            currentIndex = 0
            window?.title = "No Media"
            if isPlaylistVisible { playlistTable.reloadData() }
            return
        }
        // req 52-53
        if deletedIdx >= playlist.count { currentIndex = 0 }
        loadCurrentItem()
    }

    // MARK: Snapshot (req 43-48)

    func saveSnapshot() {
        guard let ci = player.currentItem else { showInfo("No media loaded."); return }
        let time = player.currentTime()
        let gen  = AVAssetImageGenerator(asset: ci.asset)
        gen.appliesPreferredTrackTransform   = true   // req 44
        gen.requestedTimeToleranceBefore     = .zero
        gen.requestedTimeToleranceAfter      = .zero

        gen.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { [weak self] _, img, _, result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error { self.showError("Snapshot failed:\n\(error.localizedDescription)"); return }
                guard result == .succeeded, let img else {
                    self.showError("Could not capture frame."); return
                }
                self.writeHEIC(img)
            }
        }
    }

    private func writeHEIC(_ image: CGImage) {      // req 45-48
        let df        = DateFormatter()
        df.dateFormat = "yyyyMMdd_HHmmss"
        let name      = "snapshot_\(df.string(from: Date())).heic"  // req 46
        let dest      = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                            .appendingPathComponent(name)             // req 47

        let uti = UTType.heic.identifier as CFString
        guard let imgDest = CGImageDestinationCreateWithURL(dest as CFURL, uti, 1, nil) else {
            showError("Could not create HEIC destination."); return
        }
        CGImageDestinationAddImage(imgDest, image, nil)
        if CGImageDestinationFinalize(imgDest) {
            print("Snapshot saved: \(dest.path)")   // req 48
            showInfo("Snapshot saved:\n\(dest.path)")
        } else {
            showError("Failed to write snapshot.")
        }
    }

    // MARK: Media Information (req 40-42)

    func showMediaInfo() {
        guard let ci = player.currentItem else { showInfo("No media loaded."); return }
        Task {
            do {
                let asset     = ci.asset
                let vidTracks = try await asset.loadTracks(withMediaType: .video)
                let audTracks = try await asset.loadTracks(withMediaType: .audio)
                let duration  = try await asset.load(.duration)
                var lines     = [String]()

                if !playlist.isEmpty {
                    lines.append("File: \(playlist[currentIndex].displayName)")
                }
                let s = duration.seconds
                if s.isFinite, s > 0 {
                    lines.append(String(format: "Duration: %02d:%02d:%02d",
                                        Int(s)/3600, (Int(s)%3600)/60, Int(s)%60))
                }
                for t in vidTracks {
                    let sz    = try await t.load(.naturalSize)
                    let fps   = try await t.load(.nominalFrameRate)
                    let fmts  = try await t.load(.formatDescriptions) as [CMFormatDescription]
                    let codec = fmts.first.map { CMFormatDescriptionGetMediaSubType($0).toFourCC() } ?? "?"
                    lines.append(String(format: "Video: %.0fx%.0f  %.3g fps  [%@]",
                                        sz.width, sz.height, fps, codec))
                }
                for t in audTracks {
                    let fmts  = try await t.load(.formatDescriptions) as [CMFormatDescription]
                    if let fmt = fmts.first {
                        let codec = CMFormatDescriptionGetMediaSubType(fmt).toFourCC()
                        if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt) {
                            lines.append(String(format: "Audio: %.0f Hz  [%@]",
                                                asbd.pointee.mSampleRate, codec))
                        } else {
                            lines.append("Audio codec: [\(codec)]")
                        }
                    }
                }
                let text = lines.isEmpty ? "No track information available." : lines.joined(separator: "\n")
                await MainActor.run { self.showInfo(text, title: "Media Information") }
            } catch {                              // req 42
                await MainActor.run {
                    self.showError("Could not load media info:\n\(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: Cursor (req 56-59)

    private func resetCursorTimer() {
        showCursor()
        cursorTimer?.invalidate()
        cursorTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.hideCursor() }
        }
    }

    private func stopCursorTimer() {
        cursorTimer?.invalidate()
        cursorTimer = nil
    }

    private func showCursor() {
        guard cursorHidden else { return }
        NSCursor.unhide()
        cursorHidden = false
    }

    private func hideCursor() {
        guard !cursorHidden else { return }
        NSCursor.hide()
        cursorHidden = true
    }

    private func onMouseActivity() {              // req 57
        guard window?.styleMask.contains(.fullScreen) == true,
              !isPlaylistVisible else { return }
        resetCursorTimer()
    }

    // MARK: Keyboard Dispatch (req 60)

    /// Returns true if the event was consumed.
    func dispatchKey(_ event: NSEvent) -> Bool {
        guard event.window === window else { return false }

        // Reveal cursor on any key in fullscreen (req 57)
        if window?.styleMask.contains(.fullScreen) == true, !isPlaylistVisible {
            resetCursorTimer()
        }

        // Arrow keys by keyCode (independent of keyboard layout)
        switch event.keyCode {
        case 123: seekBackward(); return true   // ←
        case 124: seekForward();  return true   // →
        default:  break
        }

        // Reject if modifiers are held (allow Cmd+Q, Cmd+W, etc. to pass through)
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                        .subtracting([.capsLock, .numericPad, .function])
        guard mods.isEmpty else { return false }

        guard let ch = event.charactersIgnoringModifiers?.uppercased() else { return false }

        switch ch {
        case "Q": NSApp.terminate(nil);             return true
        case "F": window?.toggleFullScreen(nil);    return true
        case "P": togglePlaylist();                 return true
        case "D": deleteCurrentFile();              return true
        case "S": saveSnapshot();                   return true
        case "I": showMediaInfo();                  return true
        case "N": playNext();                       return true
        case "B": playPrevious();                   return true
        case "R": restart();                        return true
        case " ": playPause();                      return true
        default:  return false
        }
    }

    // MARK: Cleanup (req 62)

    func cleanup() {
        stopCursorTimer()
        showCursor()
        keyMonitor.map   { NSEvent.removeMonitor($0) };   keyMonitor   = nil
        mouseMonitor.map { NSEvent.removeMonitor($0) };   mouseMonitor = nil
        endObs.map       { NotificationCenter.default.removeObserver($0) }
        errObs.map       { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {   // req 9
        guard !didAutoFullscreen else { return }
        didAutoFullscreen = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.window?.toggleFullScreen(nil)
        }
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        if !isPlaylistVisible { resetCursorTimer() }          // req 56
    }

    func windowDidExitFullScreen(_ notification: Notification) {  // req 59
        stopCursorTimer()
        showCursor()
    }

    func windowDidResignKey(_ notification: Notification) {    // req 59
        stopCursorTimer()
        showCursor()
    }

    func windowWillClose(_ notification: Notification) {
        cleanup()
    }

    // MARK: NSTableViewDataSource (req 28)

    func numberOfRows(in tableView: NSTableView) -> Int { playlist.count }

    // MARK: NSTableViewDelegate

    func tableView(_ tableView: NSTableView,
                   viewFor _: NSTableColumn?,
                   row: Int) -> NSView? {
        guard row < playlist.count else { return nil }
        let id = NSUserInterfaceItemIdentifier("plCell")
        let tf : NSTextField
        if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField {
            tf = reused
        } else {
            tf = NSTextField(labelWithString: "")
            tf.identifier    = id
            tf.isBordered    = false
            tf.isEditable    = false
            tf.lineBreakMode = .byTruncatingMiddle
        }
        let isCurrent    = (row == currentIndex)      // req 29
        tf.stringValue   = playlist[row].displayName
        tf.textColor     = isCurrent ? .systemBlue : NSColor(calibratedWhite: 0.9, alpha: 1)
        tf.font          = .systemFont(ofSize: 12, weight: isCurrent ? .semibold : .regular)
        tf.backgroundColor = .clear
        return tf
    }

    func tableViewSelectionDidChange(_ notification: Notification) {  // req 30
        guard !suppressSelectionChange else { return }
        let row = playlistTable.selectedRow
        guard row >= 0, row < playlist.count, row != currentIndex else { return }
        currentIndex = row
        loadCurrentItem()
    }

    // MARK: Alerts

    private func showInfo(_ text: String, title: String = "Media Player") {
        let a = NSAlert()
        a.messageText = title; a.informativeText = text
        a.runModal()
    }

    private func showError(_ text: String) {
        let a = NSAlert()
        a.messageText = "Error"; a.informativeText = text
        a.alertStyle  = .critical
        a.runModal()
    }
}

// MARK: - FourCharCode Helper

private extension FourCharCode {
    func toFourCC() -> String {
        let bytes: [UInt8] = [
            UInt8((self >> 24) & 0xff), UInt8((self >> 16) & 0xff),
            UInt8((self >>  8) & 0xff), UInt8( self        & 0xff),
        ]
        return String(bytes: bytes, encoding: .ascii)?
            .trimmingCharacters(in: .whitespaces) ?? "\(self)"
    }
}

// MARK: - AppDelegate  (req 1-4, 61-62)

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: PlayerWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // req 1-3: parse command-line argument
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            print("Usage: \(args[0]) <file_path_or_URL>")
            exit(1)
        }

        let input = args[1]
        let url: URL

        let lower = input.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            guard let u = URL(string: input) else {
                fputs("Invalid URL: \(input)\n", stderr); exit(1)
            }
            url = u
        } else {
            url = URL(fileURLWithPath: (input as NSString).expandingTildeInPath)
        }

        // req 4: create window and activate
        let wc = PlayerWindowController(inputURL: url)
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        windowController = wc
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true                                       // req 61
    }

    func applicationWillTerminate(_ notification: Notification) {
        windowController?.cleanup()                // req 62
    }
}

// MARK: - Entry Point

NSApplication.shared.setActivationPolicy(.regular)
// Top-level code in main.swift runs on the main thread; use assumeIsolated
// so Swift 6 strict concurrency accepts the @MainActor initialiser call.
let _delegate = MainActor.assumeIsolated { AppDelegate() }
NSApplication.shared.delegate = _delegate
NSApplication.shared.run()
