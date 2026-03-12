import Cocoa
import AVFoundation
import AVKit
import CoreMedia
import ImageIO
import UniformTypeIdentifiers

private enum AppConstants {
    static let windowSize = NSSize(width: 960, height: 540)
    static let playlistWidth: CGFloat = 300
    static let playlistRowHeight: CGFloat = 24
    static let playlistFontSize: CGFloat = 13
    static let snapshotCompressionQuality: CGFloat = 0.8
    static let seekStep: Float64 = 10
    static let tableColumnIdentifier = NSUserInterfaceItemIdentifier("MainColumn")
    static let usage = "Usage: avplayer <url_or_file>"
    static let emptyWindowTitle = "No Media"
    static let supportedMediaExtensions = Set(["mp4", "mov", "m4v", "avi", "mkv", "ts", "flv", "webm"])
    static let spaceKeyCode: UInt16 = 49
    static let leftArrowKeyCode: UInt16 = 123
    static let rightArrowKeyCode: UInt16 = 124
}

private enum KeyboardShortcut: String {
    case quit = "q"
    case fullscreen = "f"
    case playlist = "p"
    case delete = "d"
    case snapshot = "s"
    case info = "i"
    case next = "n"
    case previous = "b"
    case restart = "r"
}

private final class SegmentResourceLoader: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate {
    private let originalURL: URL
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }()

    private var pendingRequests: [URLSessionTask: AVAssetResourceLoadingRequest] = [:]
    private var contentType: String?
    private var contentLength: Int64 = 0

    init(url: URL) {
        self.originalURL = url
        super.init()
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        if loadingRequest.contentInformationRequest != nil {
            fillContentInformation(for: loadingRequest)
            return true
        }

        if loadingRequest.dataRequest != nil {
            processDataRequest(for: loadingRequest)
            return true
        }

        return false
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        for (task, request) in pendingRequests where request == loadingRequest {
            task.cancel()
            pendingRequests.removeValue(forKey: task)
            break
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        pendingRequests[dataTask]?.dataRequest?.respond(with: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let loadingRequest = pendingRequests.removeValue(forKey: task) else { return }

        if let error {
            loadingRequest.finishLoading(with: error)
            return
        }

        loadingRequest.finishLoading()
    }

    private func fillContentInformation(for loadingRequest: AVAssetResourceLoadingRequest) {
        if contentLength > 0 {
            completeContentInformation(for: loadingRequest)
            return
        }

        var request = URLRequest(url: originalURL)
        request.httpMethod = "HEAD"

        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            guard let self else { return }

            if let error {
                loadingRequest.finishLoading(with: error)
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                loadingRequest.finishLoading(with: NSError(domain: NSURLErrorDomain, code: NSURLErrorBadServerResponse))
                return
            }

            self.contentLength = httpResponse.expectedContentLength
            self.contentType = httpResponse.mimeType ?? "video/mp4"

            DispatchQueue.main.async {
                self.completeContentInformation(for: loadingRequest)
            }
        }.resume()
    }

    private func completeContentInformation(for loadingRequest: AVAssetResourceLoadingRequest) {
        guard let informationRequest = loadingRequest.contentInformationRequest else {
            loadingRequest.finishLoading()
            return
        }

        informationRequest.isByteRangeAccessSupported = true
        informationRequest.contentType = contentType
        informationRequest.contentLength = contentLength
        loadingRequest.finishLoading()
    }

    private func processDataRequest(for loadingRequest: AVAssetResourceLoadingRequest) {
        guard let dataRequest = loadingRequest.dataRequest else { return }

        let requestedOffset = dataRequest.currentOffset != 0 ? dataRequest.currentOffset : dataRequest.requestedOffset
        let requestedLength = Int64(dataRequest.requestedLength)
        guard requestedLength > 0 else {
            loadingRequest.finishLoading()
            return
        }

        let rangeHeader = "bytes=\(requestedOffset)-\(requestedOffset + requestedLength - 1)"

        var request = URLRequest(url: originalURL)
        request.setValue(rangeHeader, forHTTPHeaderField: "Range")

        let task = session.dataTask(with: request)
        pendingRequests[task] = loadingRequest
        task.resume()
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private var playlist: [URL]
    private var currentIndex: Int

    private var window: NSWindow!
    private var playerView: AVPlayerView!
    private let player = AVPlayer()
    private var playlistScrollView: NSScrollView!
    private var playlistTableView: NSTableView!
    private var isProgrammaticSelection = false
    private var keyboardMonitor: Any?
    private var resourceLoader: SegmentResourceLoader?

    init(url: URL) {
        let resolvedPlaylist = Self.makePlaylist(for: url)
        self.playlist = resolvedPlaylist.urls
        self.currentIndex = resolvedPlaylist.currentIndex
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureWindow()
        configurePlayerView()
        configurePlaylistUI()

        playerView.player = player
        playVideo(at: currentIndex)

        window.makeKeyAndOrderFront(nil)
        window.toggleFullScreen(nil)
        NSApp.activate(ignoringOtherApps: true)
        installKeyboardMonitor()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let keyboardMonitor {
            NSEvent.removeMonitor(keyboardMonitor)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        playlist.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let textField = NSTextField(labelWithString: playlist[row].lastPathComponent)
        textField.textColor = row == currentIndex ? .systemYellow : .white
        textField.font = row == currentIndex
            ? .boldSystemFont(ofSize: AppConstants.playlistFontSize)
            : .systemFont(ofSize: AppConstants.playlistFontSize)
        return textField
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        AppConstants.playlistRowHeight
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isProgrammaticSelection else { return }

        let selectedRow = playlistTableView.selectedRow
        guard selectedRow >= 0, selectedRow < playlist.count, selectedRow != currentIndex else { return }

        playVideo(at: selectedRow)
    }

    private func configureWindow() {
        let frame = NSRect(origin: .zero, size: AppConstants.windowSize)
        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.backgroundColor = .black
        window.collectionBehavior = .fullScreenPrimary
        window.center()
        window.delegate = self
    }

    private func configurePlayerView() {
        guard let contentView = window.contentView else { return }

        playerView = AVPlayerView(frame: contentView.bounds)
        playerView.autoresizingMask = [.width, .height]
        playerView.controlsStyle = .none
        contentView.addSubview(playerView)
    }

    private func configurePlaylistUI() {
        guard let contentView = window.contentView else { return }

        playlistScrollView = NSScrollView()
        playlistScrollView.translatesAutoresizingMaskIntoConstraints = false
        playlistScrollView.wantsLayer = true
        playlistScrollView.drawsBackground = true
        playlistScrollView.backgroundColor = NSColor(white: 0.1, alpha: 0.9)
        playlistScrollView.hasVerticalScroller = true
        playlistScrollView.isHidden = true
        contentView.addSubview(playlistScrollView, positioned: .above, relativeTo: nil)

        NSLayoutConstraint.activate([
            playlistScrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            playlistScrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            playlistScrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            playlistScrollView.widthAnchor.constraint(equalToConstant: AppConstants.playlistWidth)
        ])

        playlistTableView = NSTableView()
        let column = NSTableColumn(identifier: AppConstants.tableColumnIdentifier)
        column.width = AppConstants.playlistWidth - 20
        playlistTableView.addTableColumn(column)
        playlistTableView.delegate = self
        playlistTableView.dataSource = self
        playlistTableView.headerView = nil
        playlistTableView.backgroundColor = .clear
        playlistTableView.appearance = NSAppearance(named: .darkAqua)
        playlistTableView.style = .fullWidth

        playlistScrollView.documentView = playlistTableView
    }

    private func playVideo(at index: Int) {
        guard !playlist.isEmpty else {
            player.replaceCurrentItem(with: nil)
            window.title = AppConstants.emptyWindowTitle
            return
        }

        currentIndex = normalizedPlaylistIndex(for: index)
        let url = playlist[currentIndex]
        window.title = "[\(currentIndex + 1)/\(playlist.count)] \(url.lastPathComponent)"

        let playbackConfiguration = makePlaybackConfiguration(for: url)
        resourceLoader = playbackConfiguration.resourceLoader

        let asset = AVURLAsset(url: playbackConfiguration.assetURL)
        if let resourceLoader {
            asset.resourceLoader.setDelegate(resourceLoader, queue: .main)
        }

        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)
        player.play()
        syncPlaylistSelection()
    }

    private func syncPlaylistSelection() {
        guard playlistTableView != nil, !playlist.isEmpty else { return }

        isProgrammaticSelection = true
        playlistTableView.selectRowIndexes(IndexSet(integer: currentIndex), byExtendingSelection: false)
        playlistTableView.scrollRowToVisible(currentIndex)
        playlistTableView.reloadData()
        isProgrammaticSelection = false
    }

    private func deleteCurrentVideoDirectly() {
        guard !playlist.isEmpty else { return }

        let urlToDelete = playlist[currentIndex]
        guard urlToDelete.isFileURL else {
            showAlert(title: "Delete Failed", message: "Only local files can be deleted.")
            return
        }
        player.pause()

        do {
            try FileManager.default.removeItem(at: urlToDelete)
            NSSound.beep()
            playlist.remove(at: currentIndex)

            if playlist.isEmpty {
                player.replaceCurrentItem(with: nil)
                window.title = AppConstants.emptyWindowTitle
                playlistTableView.reloadData()
                return
            }

            currentIndex = min(currentIndex, playlist.count - 1)
            playVideo(at: currentIndex)
        } catch {
            showAlert(title: "Delete Failed", message: error.localizedDescription)
        }
    }

    private func installKeyboardMonitor() {
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }

            if handleCharacterShortcut(for: event) {
                return nil
            }

            switch event.keyCode {
            case AppConstants.spaceKeyCode:
                togglePlayback()
                return nil
            case AppConstants.leftArrowKeyCode:
                seek(by: -AppConstants.seekStep)
                return nil
            case AppConstants.rightArrowKeyCode:
                seek(by: AppConstants.seekStep)
                return nil
            default:
                return event
            }
        }
    }

    private func handleCharacterShortcut(for event: NSEvent) -> Bool {
        guard let value = event.charactersIgnoringModifiers?.lowercased(),
              let shortcut = KeyboardShortcut(rawValue: value) else {
            return false
        }

        switch shortcut {
        case .quit:
            NSApp.terminate(nil)
        case .fullscreen:
            window.toggleFullScreen(nil)
        case .playlist:
            playlistScrollView.isHidden.toggle()
            if !playlistScrollView.isHidden {
                syncPlaylistSelection()
            }
        case .delete:
            deleteCurrentVideoDirectly()
        case .snapshot:
            saveSnapshot()
        case .info:
            showMediaInfo()
        case .next:
            playVideo(at: currentIndex + 1)
        case .previous:
            playVideo(at: currentIndex - 1)
        case .restart:
            player.seek(to: .zero)
            player.play()
        }

        return true
    }

    private func togglePlayback() {
        if player.rate == 0 {
            player.play()
        } else {
            player.pause()
        }
    }

    private func seek(by seconds: Float64) {
        let currentTime = player.currentTime()
        let targetTime = CMTimeAdd(currentTime, CMTime(seconds: seconds, preferredTimescale: 1))
        player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func showMediaInfo() {
        guard let currentItem = player.currentItem, !playlist.isEmpty else { return }

        let asset = currentItem.asset
        let fileName = playlist[currentIndex].lastPathComponent

        Task {
            do {
                let info = try await Self.makeMediaInfo(for: asset, fileName: fileName)
                await MainActor.run {
                    self.showAlert(title: "Media Information", message: info)
                }
            } catch {
                await MainActor.run {
                    self.showAlert(title: "Error", message: error.localizedDescription)
                }
            }
        }
    }

    private func saveSnapshot() {
        guard let asset = player.currentItem?.asset else { return }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true

        let currentTime = player.currentTime()
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: currentTime)]) { _, image, _, result, error in
            guard result == .succeeded, let image else {
                if let error {
                    DispatchQueue.main.async {
                        self.showAlert(title: "Snapshot Failed", message: error.localizedDescription)
                    }
                }
                return
            }

            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                data as CFMutableData,
                UTType.heic.identifier as CFString,
                1,
                nil
            ) else {
                return
            }

            CGImageDestinationAddImage(
                destination,
                image,
                [kCGImageDestinationLossyCompressionQuality as String: AppConstants.snapshotCompressionQuality] as CFDictionary
            )

            guard CGImageDestinationFinalize(destination) else { return }

            let outputURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("snapshot_\(Int(Date().timeIntervalSince1970)).heic")

            do {
                try data.write(to: outputURL)
                DispatchQueue.main.async {
                    NSSound.beep()
                    print("Saved: \(outputURL.path)")
                }
            } catch {
                DispatchQueue.main.async {
                    self.showAlert(title: "Snapshot Failed", message: error.localizedDescription)
                }
            }
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    private func normalizedPlaylistIndex(for index: Int) -> Int {
        guard !playlist.isEmpty else { return 0 }
        if index < 0 { return playlist.count - 1 }
        if index >= playlist.count { return 0 }
        return index
    }

    private func makePlaybackConfiguration(for url: URL) -> (assetURL: URL, resourceLoader: SegmentResourceLoader?) {
        guard let scheme = url.scheme?.lowercased(), scheme.hasPrefix("http") else {
            return (url, nil)
        }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = "streaming"
        let assetURL = components?.url ?? url
        return (assetURL, SegmentResourceLoader(url: url))
    }

    private static func makePlaylist(for initialURL: URL) -> (urls: [URL], currentIndex: Int) {
        guard initialURL.isFileURL else {
            return ([initialURL], 0)
        }

        let resolvedTargetPath = initialURL.resolvingSymlinksInPath().path
        let directoryURL = initialURL.deletingLastPathComponent()
        let fileManager = FileManager.default

        do {
            let fileURLs = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.contentTypeKey],
                options: .skipsHiddenFiles
            )

            let videoFiles = fileURLs
                .filter(Self.isSupportedMediaFile)
                .sorted {
                    $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
                }

            let currentIndex = videoFiles.firstIndex(where: {
                $0.resolvingSymlinksInPath().path == resolvedTargetPath
            }) ?? 0

            return (videoFiles.isEmpty ? [initialURL] : videoFiles, currentIndex)
        } catch {
            return ([initialURL], 0)
        }
    }

    private static func isSupportedMediaFile(_ url: URL) -> Bool {
        if AppConstants.supportedMediaExtensions.contains(url.pathExtension.lowercased()) {
            return true
        }

        guard let resourceValues = try? url.resourceValues(forKeys: [.contentTypeKey]),
              let contentType = resourceValues.contentType else {
            return false
        }

        return AVURLAsset.audiovisualTypes().contains {
            guard let supportedType = UTType($0.rawValue) else { return false }
            return contentType.conforms(to: supportedType)
        }
    }

    private static func makeMediaInfo(for asset: AVAsset, fileName: String) async throws -> String {
        let duration = try await asset.load(.duration)
        let tracks = try await asset.load(.tracks)
        var lines = [
            "File: \(fileName)",
            "Duration: \(String(format: "%.2f", CMTimeGetSeconds(duration)))s"
        ]

        for track in tracks {
            if track.mediaType == .video {
                let size = try await track.load(.naturalSize)
                let fps = try await track.load(.nominalFrameRate)
                let formatDescriptions = try await track.load(.formatDescriptions)
                lines.append(contentsOf: [
                    "",
                    "[Video Track]",
                    "Res: \(Int(size.width))x\(Int(size.height))",
                    "FPS: \(fps)"
                ])

                if let description = formatDescriptions.first {
                    let codec = CMFormatDescriptionGetMediaSubType(description)
                    lines.append("Codec: \(fourCCString(codec))")
                }
            } else if track.mediaType == .audio {
                let formatDescriptions = try await track.load(.formatDescriptions)
                lines.append(contentsOf: ["", "[Audio Track]"])

                if let description = formatDescriptions.first,
                   let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description) {
                    lines.append("Sample Rate: \(streamDescription.pointee.mSampleRate) Hz")
                    lines.append("Format: \(fourCCString(streamDescription.pointee.mFormatID))")
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    private static func fourCCString(_ code: FourCharCode) -> String {
        let value = Int(code)
        let string = [
            UnicodeScalar((value >> 24) & 0xFF),
            UnicodeScalar((value >> 16) & 0xFF),
            UnicodeScalar((value >> 8) & 0xFF),
            UnicodeScalar(value & 0xFF)
        ]
        .compactMap { $0 }
        .map(String.init)
        .joined()
        .trimmingCharacters(in: .whitespaces)

        return string.isEmpty ? "Unknown" : string
    }
}

private func makeInputURL(from input: String) -> URL? {
    if input.hasPrefix("http://") || input.hasPrefix("https://") {
        return URL(string: input)
    }

    return URL(fileURLWithPath: input)
}

let arguments = CommandLine.arguments

guard arguments.count >= 2, let inputURL = makeInputURL(from: arguments[1]) else {
    print(AppConstants.usage)
    exit(1)
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
private let appDelegate = AppDelegate(url: inputURL)
app.delegate = appDelegate
app.run()
