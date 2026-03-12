//swiftc -framework Cocoa -framework AVFoundation -framework CoreMedia -framework UniformTypeIdentifiers -framework AVKit main.swift -o avplayer

import AVFoundation
import AVKit
import Cocoa
import CoreMedia
import ImageIO
import UniformTypeIdentifiers

// MARK: - Constants

private enum Constants {
    enum Window {
        static let defaultFrame = NSRect(x: 0, y: 0, width: 960, height: 540)
        static let title = "No Media"
    }

    enum Playlist {
        static let panelWidth: CGFloat = 300
        static let columnWidth: CGFloat = 280
        static let rowHeight: CGFloat = 24
        static let fontSize: CGFloat = 13
        static let background = NSColor(white: 0.1, alpha: 0.9)
        static let cellID = NSUserInterfaceItemIdentifier("Cell")
        static let columnID = NSUserInterfaceItemIdentifier("Column")
    }

    enum Seek {
        static let interval: Float64 = 10
        static let timescale: CMTimeScale = 1
    }

    enum Cursor {
        static let hideDelay: TimeInterval = 2.5
    }

    enum Snapshot {
        static let compressionQuality: CGFloat = 0.8
    }
}

// MARK: - StreamingResourceLoader

/// Intercepts `streaming://` URLs and proxies them as byte-range HTTP requests,
/// enabling AVFoundation to seek into remote files without downloading everything first.
final class StreamingResourceLoader: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate {

    private let remoteURL: URL

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    // Active loading requests keyed by their URLSession task identifier.
    private var activeTasks: [Int: AVAssetResourceLoadingRequest] = [:]

    // Reverse map: loading request → task (for cancellation).
    private var requestToTask: [ObjectIdentifier: URLSessionTask] = [:]

    // Content-information state
    private var contentLength: Int64 = 0
    private var contentType: String?
    private var isFetchingMetadata = false
    private var pendingMetadataRequests: [ObjectIdentifier: AVAssetResourceLoadingRequest] = [:]

    init(remoteURL: URL) {
        self.remoteURL = remoteURL
        super.init()
    }

    // MARK: AVAssetResourceLoaderDelegate

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest
    ) -> Bool {
        if request.contentInformationRequest != nil {
            handleMetadataRequest(request)
        }
        if request.dataRequest != nil {
            handleDataRequest(request)
        }
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel request: AVAssetResourceLoadingRequest
    ) {
        let id = ObjectIdentifier(request)
        pendingMetadataRequests.removeValue(forKey: id)

        if let task = requestToTask.removeValue(forKey: id) {
            activeTasks.removeValue(forKey: task.taskIdentifier)
            task.cancel()
        }
    }

    // MARK: Metadata

    private var hasMetadata: Bool { contentLength > 0 }

    private func handleMetadataRequest(_ request: AVAssetResourceLoadingRequest) {
        if hasMetadata {
            populateMetadata(into: request)
            finishMetadataOnlyRequest(request)
            return
        }

        pendingMetadataRequests[ObjectIdentifier(request)] = request
        guard !isFetchingMetadata else { return }

        isFetchingMetadata = true
        fetchMetadata()
    }

    private func fetchMetadata() {
        // Try HEAD first; fall back to a 1-byte GET if the server doesn't support it.
        runMetadataTask(makeHeadRequest()) { [weak self] response, error in
            guard let self else { return }

            if self.applyMetadata(from: response) {
                self.flushMetadataRequests(error: nil)
            } else {
                self.runMetadataTask(self.makeRangeRequest(offset: 0, length: 1)) { [weak self] fb, fbErr in
                    guard let self else { return }
                    _ = self.applyMetadata(from: fb)
                    self.flushMetadataRequests(error: fbErr ?? error)
                }
            }
        }
    }

    private func runMetadataTask(
        _ request: URLRequest,
        completion: @escaping (URLResponse?, Error?) -> Void
    ) {
        session.dataTask(with: request) { _, response, error in
            DispatchQueue.main.async { completion(response, error) }
        }.resume()
    }

    @discardableResult
    private func applyMetadata(from response: URLResponse?) -> Bool {
        guard let http = response as? HTTPURLResponse else { return false }
        contentLength = extractContentLength(from: http)
        contentType = extractContentType(from: http)
        return hasMetadata
    }

    private func extractContentLength(from response: HTTPURLResponse) -> Int64 {
        if response.expectedContentLength > 0 {
            return response.expectedContentLength
        }

        return response.value(forHTTPHeaderField: "Content-Range")
            .flatMap { range in
                range.split(separator: "/").last.flatMap { Int64($0) }
            } ?? 0
    }

    private func extractContentType(from response: HTTPURLResponse) -> String {
        if let mime = response.mimeType, let type = UTType(mimeType: mime) {
            return type.identifier
        }

        let ext = remoteURL.pathExtension
        if !ext.isEmpty, let type = UTType(filenameExtension: ext) {
            return type.identifier
        }

        return UTType.mpeg4Movie.identifier
    }

    private func populateMetadata(into request: AVAssetResourceLoadingRequest) {
        guard let info = request.contentInformationRequest else { return }
        info.isByteRangeAccessSupported = true
        info.contentLength = contentLength
        info.contentType = contentType
    }

    private func finishMetadataOnlyRequest(_ request: AVAssetResourceLoadingRequest) {
        if request.dataRequest == nil {
            request.finishLoading()
        }
    }

    private func flushMetadataRequests(error: Error?) {
        isFetchingMetadata = false
        let requests = pendingMetadataRequests.values
        pendingMetadataRequests.removeAll()

        for request in requests {
            if hasMetadata {
                populateMetadata(into: request)
                finishMetadataOnlyRequest(request)
            } else {
                request.finishLoading(with: error)
            }
        }
    }

    // MARK: Data

    private func handleDataRequest(_ request: AVAssetResourceLoadingRequest) {
        guard let dataRequest = request.dataRequest else { return }

        let offset = dataRequest.currentOffset != 0
            ? dataRequest.currentOffset
            : dataRequest.requestedOffset

        let urlRequest = makeRangeRequest(offset: offset, length: dataRequest.requestedLength)
        let task = session.dataTask(with: urlRequest)

        activeTasks[task.taskIdentifier] = request
        requestToTask[ObjectIdentifier(request)] = task
        task.resume()
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        activeTasks[dataTask.taskIdentifier]?.dataRequest?.respond(with: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let request = activeTasks.removeValue(forKey: task.taskIdentifier) else { return }
        requestToTask.removeValue(forKey: ObjectIdentifier(request))

        if let error {
            request.finishLoading(with: error)
        } else {
            request.finishLoading()
        }
    }

    // MARK: Helpers

    private func makeHeadRequest() -> URLRequest {
        var r = URLRequest(url: remoteURL)
        r.httpMethod = "HEAD"
        return r
    }

    private func makeRangeRequest(offset: Int64, length: Int) -> URLRequest {
        var r = URLRequest(url: remoteURL)
        let upper = offset + Int64(max(length, 1)) - 1
        r.setValue("bytes=\(offset)-\(upper)", forHTTPHeaderField: "Range")
        return r
    }
}

// MARK: - Playlist

struct Playlist {
    let urls: [URL]
    let startIndex: Int

    static func build(from url: URL) -> Playlist {
        guard url.isFileURL else {
            return Playlist(urls: [url], startIndex: 0)
        }

        let siblings = (try? Scanner.mediaFiles(near: url)) ?? []
        guard !siblings.isEmpty else {
            return Playlist(urls: [url], startIndex: 0)
        }

        let target = url.resolvingSymlinksInPath().path
        let index = siblings.firstIndex { $0.resolvingSymlinksInPath().path == target } ?? 0
        return Playlist(urls: siblings, startIndex: index)
    }

    private enum Scanner {
        private static let knownExtensions: Set<String> = [
            "mp4", "mov", "m4v", "avi", "mkv", "ts", "flv", "webm"
        ]

        private static let avTypes = AVURLAsset.audiovisualTypes()
            .compactMap { UTType($0.rawValue) }

        static func mediaFiles(near url: URL) throws -> [URL] {
            let dir = url.deletingLastPathComponent()
            let contents = try FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentTypeKey],
                options: .skipsHiddenFiles
            )
            return contents
                .filter(isPlayable)
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        }

        private static func isPlayable(_ url: URL) -> Bool {
            if knownExtensions.contains(url.pathExtension.lowercased()) { return true }
            guard
                let values = try? url.resourceValues(forKeys: [.contentTypeKey]),
                let type = values.contentType
            else { return false }
            return avTypes.contains { type.conforms(to: $0) }
        }
    }
}

// MARK: - KeyboardShortcut

enum KeyboardShortcut {
    case quit
    case toggleFullscreen
    case togglePlaylist
    case deleteCurrent
    case saveSnapshot
    case showMediaInfo
    case next
    case previous
    case restart
    case togglePlayback
    case seekBackward
    case seekForward

    init?(event: NSEvent) {
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "q": self = .quit
        case "f": self = .toggleFullscreen
        case "p": self = .togglePlaylist
        case "d": self = .deleteCurrent
        case "s": self = .saveSnapshot
        case "i": self = .showMediaInfo
        case "n": self = .next
        case "b": self = .previous
        case "r": self = .restart
        default:
            switch event.keyCode {
            case 49:  self = .togglePlayback  // Space
            case 123: self = .seekBackward    // ←
            case 124: self = .seekForward     // →
            default:  return nil
            }
        }
    }
}

// MARK: - PlayerController

/// Owns the AVPlayer, resource loading, and playback logic.
final class PlayerController {
    let player = AVPlayer()

    private var urls: [URL] = []
    private(set) var currentIndex: Int = 0
    private var resourceLoader: StreamingResourceLoader?

    var onTrackChange: ((Int, URL) -> Void)?

    // MARK: Playlist

    func load(playlist: Playlist) {
        urls = playlist.urls
        currentIndex = playlist.startIndex
        play(at: currentIndex, notify: false)
    }

    func playNext()     { play(at: currentIndex + 1) }
    func playPrevious() { play(at: currentIndex - 1) }
    func restart()      { player.seek(to: .zero); player.play() }

    func play(at index: Int, notify: Bool = true) {
        guard !urls.isEmpty else { return }

        currentIndex = wrapping(index, in: urls.count)
        let url = urls[currentIndex]

        resourceLoader = url.isFileURL ? nil : StreamingResourceLoader(remoteURL: url)

        let asset = AVURLAsset(url: streamingURL(for: url))
        if let loader = resourceLoader {
            asset.resourceLoader.setDelegate(loader, queue: .main)
        }

        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        player.play()

        if notify { onTrackChange?(currentIndex, url) }
    }

    func deleteCurrentFile() throws {
        guard !urls.isEmpty else { return }
        let url = urls[currentIndex]
        guard url.isFileURL else { throw PlayerError.notLocalFile }

        player.pause()
        try FileManager.default.removeItem(at: url)
        urls.remove(at: currentIndex)

        if urls.isEmpty {
            player.replaceCurrentItem(with: nil)
        } else {
            play(at: currentIndex)
        }
    }

    var currentURL: URL? { urls.indices.contains(currentIndex) ? urls[currentIndex] : nil }
    var playlistURLs: [URL] { urls }
    var count: Int { urls.count }

    // MARK: Seek

    func seek(by seconds: Float64) {
        let newTime = CMTimeAdd(
            player.currentTime(),
            CMTime(seconds: seconds, preferredTimescale: Constants.Seek.timescale)
        )
        player.seek(to: newTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: Snapshot

    func captureSnapshot(completion: @escaping (URL?) -> Void) {
        guard let asset = player.currentItem?.asset else { completion(nil); return }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true

        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: player.currentTime())]) { _, image, _, result, _ in
            guard result == .succeeded, let image else { completion(nil); return }

            let data = NSMutableData()
            guard
                let dest = CGImageDestinationCreateWithData(
                    data as CFMutableData,
                    UTType.heic.identifier as CFString, 1, nil
                )
            else { completion(nil); return }

            CGImageDestinationAddImage(
                dest, image,
                [kCGImageDestinationLossyCompressionQuality as String: Constants.Snapshot.compressionQuality] as CFDictionary
            )
            guard CGImageDestinationFinalize(dest) else { completion(nil); return }

            let outputURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("snapshot_\(Int(Date().timeIntervalSince1970)).heic")
            try? data.write(to: outputURL)

            DispatchQueue.main.async { completion(outputURL) }
        }
    }

    // MARK: Media Info

    func buildMediaInfo() async throws -> String {
        guard
            let item = player.currentItem,
            let url = currentURL
        else { throw PlayerError.noActiveItem }

        let asset = await item.asset
        let duration = try await asset.load(.duration)
        let tracks = try await asset.load(.tracks)

        var lines = [
            "File: \(url.lastPathComponent)",
            "Duration: \(String(format: "%.2f", CMTimeGetSeconds(duration)))s"
        ]

        for track in tracks {
            switch track.mediaType {
            case .video: lines.append(try await describeVideo(track))
            case .audio: lines.append(try await describeAudio(track))
            default: continue
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: Private

    private func describeVideo(_ track: AVAssetTrack) async throws -> String {
        let size = try await track.load(.naturalSize)
        let fps  = try await track.load(.nominalFrameRate)
        let fmts = try await track.load(.formatDescriptions)
        var lines = ["", "[Video]", "Res: \(Int(size.width))×\(Int(size.height))", "FPS: \(fps)"]
        if let fmt = fmts.first {
            lines.append("Codec: \(fourCC(CMFormatDescriptionGetMediaSubType(fmt)))")
        }
        return lines.joined(separator: "\n")
    }

    private func describeAudio(_ track: AVAssetTrack) async throws -> String {
        let fmts = try await track.load(.formatDescriptions)
        var lines = ["", "[Audio]"]
        if let fmt = fmts.first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt) {
            lines.append("Sample Rate: \(asbd.pointee.mSampleRate) Hz")
            lines.append("Format: \(fourCC(asbd.pointee.mFormatID))")
        }
        return lines.joined(separator: "\n")
    }

    private func streamingURL(for url: URL) -> URL {
        guard
            ["http", "https"].contains(url.scheme?.lowercased()),
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }

        components.scheme = "streaming"
        return components.url ?? url
    }

    private func wrapping(_ index: Int, in count: Int) -> Int {
        guard count > 0 else { return 0 }
        let r = index % count
        return r >= 0 ? r : r + count
    }

    private func fourCC(_ code: FourCharCode) -> String {
        let i = Int(code)
        let bytes: [Int] = [(i >> 24) & 0xFF, (i >> 16) & 0xFF, (i >> 8) & 0xFF, i & 0xFF]
        let scalars = bytes.compactMap { UnicodeScalar($0) }
        let chars = scalars.map { String($0) }.joined()
        let trimmed = chars.trimmingCharacters(in: CharacterSet.whitespaces)
        return trimmed.isEmpty ? "Unknown" : trimmed
    }
}

enum PlayerError: LocalizedError {
    case notLocalFile
    case noActiveItem

    var errorDescription: String? {
        switch self {
        case .notLocalFile:  return "Only local files can be deleted."
        case .noActiveItem:  return "No media is currently loaded."
        }
    }
}

// MARK: - PlaylistPanel

/// A self-contained sidebar that shows the current playlist.
final class PlaylistPanel: NSScrollView, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()

    var urls: [URL] = [] {
        didSet { table.reloadData() }
    }

    var currentIndex: Int = -1 {
        didSet { table.reloadData() }
    }

    /// Called when the user clicks a row. Passes the selected index.
    var onSelection: ((Int) -> Void)?

    private var suppressSelectionCallback = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        drawsBackground = true
        backgroundColor = Constants.Playlist.background
        hasVerticalScroller = true
        isHidden = true

        let column = NSTableColumn(identifier: Constants.Playlist.columnID)
        column.width = Constants.Playlist.columnWidth
        column.title = "Playlist"

        table.addTableColumn(column)
        table.delegate = self
        table.dataSource = self
        table.headerView = nil
        table.backgroundColor = .clear
        table.appearance = NSAppearance(named: .darkAqua)
        table.style = .fullWidth
        table.selectionHighlightStyle = .regular

        documentView = table
    }

    func syncSelection(to index: Int) {
        suppressSelectionCallback = true
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        table.scrollRowToVisible(index)
        suppressSelectionCallback = false
    }

    // MARK: NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { urls.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: Constants.Playlist.cellID, owner: self) as? NSTableCellView)
            ?? makeCell()
        configure(cell: cell, row: row)
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        Constants.Playlist.rowHeight
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelectionCallback else { return }
        let row = table.selectedRow
        guard urls.indices.contains(row), row != currentIndex else { return }
        onSelection?(row)
    }

    // MARK: Cell

    private func makeCell() -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = Constants.Playlist.cellID

        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        cell.textField = label
        cell.addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])

        return cell
    }

    private func configure(cell: NSTableCellView, row: Int) {
        let isCurrent = row == currentIndex
        cell.textField?.stringValue = urls[row].lastPathComponent
        cell.textField?.textColor = isCurrent ? .systemYellow : .white
        cell.textField?.font = isCurrent
            ? .boldSystemFont(ofSize: Constants.Playlist.fontSize)
            : .systemFont(ofSize: Constants.Playlist.fontSize)
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    private var window: NSWindow!
    private var playerView: AVPlayerView!
    private let controller = PlayerController()
    private let panel = PlaylistPanel()

    private var cursorTimer: Timer?
    private var eventMonitors: [Any] = []

    init(url: URL) {
        super.init()
        let playlist = Playlist.build(from: url)
        controller.load(playlist: playlist)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildWindow()
        buildPlayerView()
        buildPlaylistPanel()

        playerView.player = controller.player
        refreshPlaylistPanel()

        controller.onTrackChange = { [weak self] index, url in
            self?.handleTrackChange(index: index, url: url)
        }

        window.makeKeyAndOrderFront(nil)
        window.toggleFullScreen(nil)
        NSApp.activate(ignoringOtherApps: true)

        installKeyboardMonitor()
        installMouseMonitor()
        scheduleCursorHide()
    }

    // MARK: Window & View Setup

    private func buildWindow() {
        window = NSWindow(
            contentRect: Constants.Window.defaultFrame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.backgroundColor = .black
        window.collectionBehavior = .fullScreenPrimary
        window.acceptsMouseMovedEvents = true
        window.center()
        window.delegate = self
        updateWindowTitle()
    }

    private func buildPlayerView() {
        guard let content = window.contentView else { return }
        playerView = AVPlayerView(frame: content.bounds)
        playerView.autoresizingMask = [.width, .height]
        playerView.controlsStyle = .floating
        content.addSubview(playerView)
    }

    private func buildPlaylistPanel() {
        guard let content = window.contentView else { return }
        content.addSubview(panel, positioned: .above, relativeTo: nil)

        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            panel.topAnchor.constraint(equalTo: content.topAnchor),
            panel.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            panel.widthAnchor.constraint(equalToConstant: Constants.Playlist.panelWidth)
        ])

        panel.onSelection = { [weak self] index in
            self?.controller.play(at: index)
            self?.refreshPlaylistPanel()
        }
    }

    // MARK: Track Change

    private func handleTrackChange(index: Int, url: URL) {
        updateWindowTitle()
        refreshPlaylistPanel()
        scheduleCursorHide()
    }

    private func updateWindowTitle() {
        guard let url = controller.currentURL else {
            window.title = Constants.Window.title
            return
        }
        window.title = "[\(controller.currentIndex + 1)/\(controller.count)] \(url.lastPathComponent)"
    }

    private func refreshPlaylistPanel() {
        panel.urls = controller.playlistURLs
        panel.currentIndex = controller.currentIndex
        panel.syncSelection(to: controller.currentIndex)
    }

    // MARK: Input

    private func installKeyboardMonitor() {
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let shortcut = KeyboardShortcut(event: event) else { return event }
            self.handle(shortcut)
            return nil
        }
        if let monitor { eventMonitors.append(monitor) }
    }

    private func installMouseMonitor() {
        let mask: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel
        ]
        let monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.scheduleCursorHide()
            return event
        }
        if let monitor { eventMonitors.append(monitor) }
    }

    private func handle(_ shortcut: KeyboardShortcut) {
        switch shortcut {
        case .quit:
            NSApp.terminate(nil)

        case .toggleFullscreen:
            window.toggleFullScreen(nil)

        case .togglePlaylist:
            panel.isHidden.toggle()
            if !panel.isHidden { refreshPlaylistPanel() }
            scheduleCursorHide()

        case .deleteCurrent:
            deleteCurrent()

        case .saveSnapshot:
            controller.captureSnapshot { outputURL in
                if let outputURL {
                    NSSound.beep()
                    print("Saved: \(outputURL.path)")
                }
            }

        case .showMediaInfo:
            Task {
                do {
                    let info = try await controller.buildMediaInfo()
                    await MainActor.run { self.alert(title: "Media Information", message: info) }
                } catch {
                    await MainActor.run { self.alert(title: "Error", message: error.localizedDescription) }
                }
            }

        case .next:
            controller.playNext()
            refreshPlaylistPanel()
            updateWindowTitle()

        case .previous:
            controller.playPrevious()
            refreshPlaylistPanel()
            updateWindowTitle()

        case .restart:
            controller.restart()
            scheduleCursorHide()

        case .togglePlayback:
            if controller.player.rate == 0 {
                controller.player.play()
                scheduleCursorHide()
            } else {
                controller.player.pause()
                cancelCursorHide()
            }

        case .seekBackward:
            controller.seek(by: -Constants.Seek.interval)
            scheduleCursorHide()

        case .seekForward:
            controller.seek(by: Constants.Seek.interval)
            scheduleCursorHide()
        }
    }

    private func deleteCurrent() {
        do {
            try controller.deleteCurrentFile()
            NSSound.beep()

            if controller.count == 0 {
                window.title = Constants.Window.title
                panel.urls = []
            } else {
                updateWindowTitle()
                refreshPlaylistPanel()
            }
        } catch {
            alert(title: "Delete Failed", message: error.localizedDescription)
        }
    }

    // MARK: Cursor Auto-Hide

    private func scheduleCursorHide() {
        cancelCursorHide()
        guard controller.player.timeControlStatus == .playing else { return }

        cursorTimer = Timer.scheduledTimer(
            withTimeInterval: Constants.Cursor.hideDelay,
            repeats: false
        ) { [weak self] _ in
            self?.hideCursor()
        }
    }

    private func cancelCursorHide() {
        cursorTimer?.invalidate()
        cursorTimer = nil
    }

    private func hideCursor() {
        guard controller.player.timeControlStatus == .playing,
              window?.isKeyWindow == true
        else { return }
        NSCursor.setHiddenUntilMouseMoves(true)
    }

    // MARK: Helpers

    private func alert(title: String, message: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.runModal()
    }

    // MARK: NSApplicationDelegate

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        cancelCursorHide()
        eventMonitors.forEach(NSEvent.removeMonitor)
        eventMonitors.removeAll()
    }
}

// MARK: - Entry Point

private enum CLI {
    static func resolveURL() -> URL {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            print("Usage: avplayer <url_or_file_path>")
            exit(1)
        }

        let input = args[1]

        guard input.hasPrefix("http://") || input.hasPrefix("https://") else {
            return URL(fileURLWithPath: input)
        }

        guard
            let components = URLComponents(string: input),
            let scheme = components.scheme?.lowercased(),
            ["http", "https"].contains(scheme),
            let host = components.host, !host.isEmpty,
            let url = components.url
        else {
            fputs("Invalid URL: \(input)\n", stderr)
            exit(1)
        }

        return url
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let appDelegate = AppDelegate(url: CLI.resolveURL())
app.delegate = appDelegate
app.run()
