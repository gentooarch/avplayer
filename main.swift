import Cocoa
import AVFoundation
import AVKit
import CoreMedia
import UniformTypeIdentifiers
import ImageIO

private enum AppError: LocalizedError {
    case missingInput
    case invalidRemoteURL(String)

    var errorDescription: String? {
        switch self {
        case .missingInput:
            return "Usage: avplayer <url_or_file>"
        case .invalidRemoteURL(let rawValue):
            return "Invalid URL: \(rawValue)"
        }
    }
}

private struct AppConfiguration {
    let inputURL: URL

    init(arguments: [String]) throws {
        guard arguments.count >= 2 else {
            throw AppError.missingInput
        }

        let rawValue = arguments[1].trimmingCharacters(in: .whitespacesAndNewlines)
        if rawValue.lowercased().hasPrefix("http://") || rawValue.lowercased().hasPrefix("https://") {
            guard let remoteURL = URL(string: rawValue) else {
                throw AppError.invalidRemoteURL(rawValue)
            }
            inputURL = remoteURL
            return
        }

        inputURL = URL(fileURLWithPath: rawValue).standardizedFileURL
    }
}

private struct Playlist {
    private(set) var items: [URL]
    private(set) var currentIndex: Int

    init(seedURL: URL) {
        if seedURL.isFileURL {
            let resolvedSeedPath = seedURL.resolvingSymlinksInPath().path
            let directoryURL = seedURL.deletingLastPathComponent()
            let fileManager = FileManager.default
            let commonExtensions = Set(["mp4", "mov", "m4v", "avi", "mkv", "ts", "flv", "webm"])
            let supportedTypes = AVURLAsset.audiovisualTypes().compactMap { UTType($0.rawValue) }

            do {
                let directoryItems = try fileManager.contentsOfDirectory(
                    at: directoryURL,
                    includingPropertiesForKeys: [.isRegularFileKey, .contentTypeKey],
                    options: [.skipsHiddenFiles]
                )

                let playableItems = directoryItems.filter { fileURL in
                    guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentTypeKey]), values.isRegularFile == true else {
                        return false
                    }

                    if commonExtensions.contains(fileURL.pathExtension.lowercased()) {
                        return true
                    }

                    guard let contentType = values.contentType else {
                        return false
                    }

                    return supportedTypes.contains(where: { contentType.conforms(to: $0) })
                }
                .sorted { lhs, rhs in
                    lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
                }

                items = playableItems.isEmpty ? [seedURL] : playableItems
                currentIndex = items.firstIndex(where: { $0.resolvingSymlinksInPath().path == resolvedSeedPath }) ?? 0
                return
            } catch {
            }
        }

        items = [seedURL]
        currentIndex = 0
    }

    var isEmpty: Bool {
        items.isEmpty
    }

    var currentURL: URL? {
        guard items.indices.contains(currentIndex) else {
            return nil
        }
        return items[currentIndex]
    }

    mutating func select(index requestedIndex: Int) -> URL? {
        guard !items.isEmpty else {
            currentIndex = 0
            return nil
        }

        if requestedIndex < 0 {
            currentIndex = 0
        } else if requestedIndex >= items.count {
            currentIndex = 0
        } else {
            currentIndex = requestedIndex
        }

        return items[currentIndex]
    }

    mutating func removeCurrentItem() {
        guard items.indices.contains(currentIndex) else {
            return
        }

        items.remove(at: currentIndex)
        if items.isEmpty {
            currentIndex = 0
        } else if currentIndex >= items.count {
            currentIndex = 0
        }
    }
}

private final class RemoteAssetLoader: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate, URLSessionTaskDelegate {
    private struct ContentMetadata {
        let contentTypeIdentifier: String
        let contentLength: Int64
        let isByteRangeSupported: Bool
    }

    private let originalURL: URL
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }()

    private var metadata: ContentMetadata?
    private var metadataTaskIdentifier: Int?
    private var pendingInfoRequests: [AVAssetResourceLoadingRequest] = []
    private var pendingDataRequests: [Int: AVAssetResourceLoadingRequest] = [:]

    init(originalURL: URL) {
        self.originalURL = originalURL
        super.init()
    }

    func makeStreamingURL() -> URL {
        guard var components = URLComponents(url: originalURL, resolvingAgainstBaseURL: false) else {
            return originalURL
        }
        components.scheme = "streaming"
        return components.url ?? originalURL
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        if loadingRequest.contentInformationRequest != nil {
            if let metadata {
                apply(metadata: metadata, to: loadingRequest)
                if loadingRequest.dataRequest == nil {
                    loadingRequest.finishLoading()
                    return true
                }
            } else {
                enqueueInfoRequest(loadingRequest)
                startMetadataRequestIfNeeded()
            }
        }

        if loadingRequest.dataRequest != nil {
            if let metadata {
                apply(metadata: metadata, to: loadingRequest)
            } else {
                startMetadataRequestIfNeeded()
            }
            startDataRequest(for: loadingRequest)
            return true
        }

        return loadingRequest.contentInformationRequest != nil
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        pendingInfoRequests.removeAll(where: { $0 === loadingRequest })

        if let taskIdentifier = pendingDataRequests.first(where: { $0.value === loadingRequest })?.key {
            session.getAllTasks { tasks in
                tasks.first(where: { $0.taskIdentifier == taskIdentifier })?.cancel()
            }
            pendingDataRequests.removeValue(forKey: taskIdentifier)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if metadata == nil, let parsedMetadata = makeMetadata(from: response) {
            metadata = parsedMetadata
            flushPendingInfoRequestsIfNeeded()
        }

        if let loadingRequest = pendingDataRequests[dataTask.taskIdentifier], let metadata {
            apply(metadata: metadata, to: loadingRequest)
        }

        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        pendingDataRequests[dataTask.taskIdentifier]?.dataRequest?.respond(with: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if task.taskIdentifier == metadataTaskIdentifier {
            metadataTaskIdentifier = nil

            if let error {
                let requests = pendingInfoRequests
                pendingInfoRequests.removeAll()
                requests.forEach { $0.finishLoading(with: error) }
                return
            }

            flushPendingInfoRequestsIfNeeded()
            return
        }

        guard let loadingRequest = pendingDataRequests.removeValue(forKey: task.taskIdentifier) else {
            return
        }

        if let error {
            loadingRequest.finishLoading(with: error)
        } else {
            loadingRequest.finishLoading()
        }
    }

    private func enqueueInfoRequest(_ loadingRequest: AVAssetResourceLoadingRequest) {
        guard !pendingInfoRequests.contains(where: { $0 === loadingRequest }) else {
            return
        }
        pendingInfoRequests.append(loadingRequest)
    }

    private func startMetadataRequestIfNeeded() {
        guard metadata == nil, metadataTaskIdentifier == nil else {
            return
        }

        var request = URLRequest(url: originalURL)
        request.httpMethod = "HEAD"
        let task = session.dataTask(with: request)
        metadataTaskIdentifier = task.taskIdentifier
        task.resume()
    }

    private func startDataRequest(for loadingRequest: AVAssetResourceLoadingRequest) {
        guard let dataRequest = loadingRequest.dataRequest else {
            return
        }

        guard dataRequest.requestedLength > 0 else {
            loadingRequest.finishLoading()
            return
        }

        let startOffset = dataRequest.currentOffset > 0 ? dataRequest.currentOffset : dataRequest.requestedOffset
        let endOffset = startOffset + Int64(dataRequest.requestedLength) - 1

        var request = URLRequest(url: originalURL)
        request.setValue("bytes=\(startOffset)-\(endOffset)", forHTTPHeaderField: "Range")

        let task = session.dataTask(with: request)
        pendingDataRequests[task.taskIdentifier] = loadingRequest
        task.resume()
    }

    private func flushPendingInfoRequestsIfNeeded() {
        guard let metadata else {
            return
        }

        let requests = pendingInfoRequests
        pendingInfoRequests.removeAll()

        for request in requests {
            apply(metadata: metadata, to: request)
            if request.dataRequest == nil {
                request.finishLoading()
            }
        }
    }

    private func apply(metadata: ContentMetadata, to loadingRequest: AVAssetResourceLoadingRequest) {
        guard let infoRequest = loadingRequest.contentInformationRequest else {
            return
        }

        infoRequest.contentType = metadata.contentTypeIdentifier
        infoRequest.contentLength = metadata.contentLength
        infoRequest.isByteRangeAccessSupported = metadata.isByteRangeSupported
    }

    private func makeMetadata(from response: URLResponse) -> ContentMetadata? {
        guard let httpResponse = response as? HTTPURLResponse else {
            return nil
        }

        let mimeTypeIdentifier = httpResponse.mimeType.flatMap { UTType(mimeType: $0)?.identifier }
        let extensionIdentifier = UTType(filenameExtension: originalURL.pathExtension)?.identifier
        let fallbackIdentifier = UTType.movie.identifier
        let contentTypeIdentifier = mimeTypeIdentifier ?? extensionIdentifier ?? fallbackIdentifier

        let totalLengthFromRange: Int64? = {
            guard let contentRange = httpResponse.value(forHTTPHeaderField: "Content-Range") else {
                return nil
            }
            let parts = contentRange.split(separator: "/")
            guard let lastPart = parts.last, let value = Int64(lastPart) else {
                return nil
            }
            return value
        }()

        let headerLength = httpResponse.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init)
        let expectedLength = response.expectedContentLength > 0 ? response.expectedContentLength : nil
        let resolvedLength = totalLengthFromRange ?? headerLength ?? expectedLength ?? 0
        let byteRangeSupported = httpResponse.statusCode == 206 || (httpResponse.value(forHTTPHeaderField: "Accept-Ranges")?.localizedCaseInsensitiveContains("bytes") ?? false)

        return ContentMetadata(
            contentTypeIdentifier: contentTypeIdentifier,
            contentLength: resolvedLength,
            isByteRangeSupported: byteRangeSupported
        )
    }
}

private enum MediaInformationBuilder {
    static func build(for asset: AVAsset, sourceURL: URL) async throws -> String {
        let duration = try await asset.load(.duration)
        let tracks = try await asset.load(.tracks)

        var sections: [String] = []
        sections.append("File: \(sourceURL.displayName)")
        sections.append("Duration: \(duration.formattedDuration)")

        for track in tracks {
            switch track.mediaType {
            case .video:
                let size = try await track.load(.naturalSize)
                let fps = try await track.load(.nominalFrameRate)
                let descriptions = try await track.load(.formatDescriptions)
                let codec = descriptions.first.map { formatFourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? "Unknown"
                sections.append([
                    "[Video Track]",
                    "Resolution: \(Int(size.width))x\(Int(size.height))",
                    "FPS: \(String(format: "%.2f", fps))",
                    "Codec: \(codec)"
                ].joined(separator: "\n"))

            case .audio:
                let descriptions = try await track.load(.formatDescriptions)
                var lines = ["[Audio Track]"]
                if let description = descriptions.first,
                   let basicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description) {
                    lines.append("Sample Rate: \(String(format: "%.0f", basicDescription.pointee.mSampleRate)) Hz")
                    lines.append("Format: \(formatFourCC(basicDescription.pointee.mFormatID))")
                }
                sections.append(lines.joined(separator: "\n"))

            default:
                continue
            }
        }

        return sections.joined(separator: "\n\n")
    }

}

private func formatFourCC(_ code: FourCharCode) -> String {
    let scalars = [
        UnicodeScalar((code >> 24) & 0xFF),
        UnicodeScalar((code >> 16) & 0xFF),
        UnicodeScalar((code >> 8) & 0xFF),
        UnicodeScalar(code & 0xFF)
    ]
    .compactMap { $0 }
    .map(String.init)
    .joined()
    .trimmingCharacters(in: .whitespacesAndNewlines)

    return scalars.isEmpty ? "Unknown" : scalars
}

private extension URL {
    var isHTTPFamily: Bool {
        guard let scheme else {
            return false
        }
        return scheme.caseInsensitiveCompare("http") == .orderedSame || scheme.caseInsensitiveCompare("https") == .orderedSame
    }

    var displayName: String {
        let name = lastPathComponent
        return name.isEmpty ? absoluteString : name
    }
}

private extension CMTime {
    var formattedDuration: String {
        let seconds = CMTimeGetSeconds(self)
        guard seconds.isFinite else {
            return "Unknown"
        }
        return String(format: "%.2fs", seconds)
    }
}

@MainActor
private final class PlayerApplication: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let player = AVPlayer()
    private var playlist: Playlist
    private var window: NSWindow?
    private var playerView: AVPlayerView?
    private var playlistScrollView: NSScrollView?
    private var playlistTableView: NSTableView?
    private var keyMonitor: Any?
    private var isProgrammaticSelection = false
    private var remoteAssetLoader: RemoteAssetLoader?

    init(configuration: AppConfiguration) {
        playlist = Playlist(seedURL: configuration.inputURL)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildInterface()
        installKeyboardMonitor()
        playVideo(at: playlist.currentIndex)

        window?.makeKeyAndOrderFront(nil)
        window?.toggleFullScreen(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        playlist.items.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        26
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("PlaylistCell")
        let cellView = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? makePlaylistCell(identifier: identifier)
        let textField = cellView.textField ?? NSTextField(labelWithString: "")

        textField.stringValue = playlist.items[row].displayName
        textField.textColor = row == playlist.currentIndex ? .systemYellow : .white
        textField.font = row == playlist.currentIndex ? .boldSystemFont(ofSize: 13) : .systemFont(ofSize: 13)
        textField.lineBreakMode = .byTruncatingMiddle

        if cellView.textField == nil {
            cellView.textField = textField
        }

        return cellView
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isProgrammaticSelection, let tableView = playlistTableView else {
            return
        }

        let selectedRow = tableView.selectedRow
        guard playlist.items.indices.contains(selectedRow), selectedRow != playlist.currentIndex else {
            return
        }

        playVideo(at: selectedRow)
    }

    private func buildInterface() {
        let initialFrame = NSRect(x: 0, y: 0, width: 960, height: 540)
        let window = NSWindow(
            contentRect: initialFrame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.backgroundColor = .black
        window.collectionBehavior = .fullScreenPrimary
        window.delegate = self

        let contentView = NSView(frame: initialFrame)
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.black.cgColor
        window.contentView = contentView

        let playerView = AVPlayerView()
        playerView.translatesAutoresizingMaskIntoConstraints = false
        playerView.player = player
        playerView.controlsStyle = .none
        playerView.videoGravity = .resizeAspect
        contentView.addSubview(playerView)

        let playlistScrollView = NSScrollView()
        playlistScrollView.translatesAutoresizingMaskIntoConstraints = false
        playlistScrollView.drawsBackground = true
        playlistScrollView.backgroundColor = NSColor(white: 0.08, alpha: 0.92)
        playlistScrollView.hasVerticalScroller = true
        playlistScrollView.isHidden = true
        contentView.addSubview(playlistScrollView)

        let playlistTableView = NSTableView()
        playlistTableView.frame = NSRect(x: 0, y: 0, width: 300, height: CGFloat(max(playlist.items.count, 1)) * 26)
        playlistTableView.delegate = self
        playlistTableView.dataSource = self
        playlistTableView.headerView = nil
        playlistTableView.backgroundColor = .clear
        playlistTableView.appearance = NSAppearance(named: .darkAqua)
        playlistTableView.intercellSpacing = NSSize(width: 0, height: 4)
        playlistTableView.selectionHighlightStyle = .regular

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("PlaylistColumn"))
        column.width = 280
        playlistTableView.addTableColumn(column)

        playlistScrollView.documentView = playlistTableView

        NSLayoutConstraint.activate([
            playerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            playerView.topAnchor.constraint(equalTo: contentView.topAnchor),
            playerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            playlistScrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            playlistScrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            playlistScrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            playlistScrollView.widthAnchor.constraint(equalToConstant: 300)
        ])

        self.window = window
        self.playerView = playerView
        self.playlistScrollView = playlistScrollView
        self.playlistTableView = playlistTableView
    }

    private func makePlaylistCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cellView = NSTableCellView()
        cellView.identifier = identifier

        let textField = NSTextField(labelWithString: "")
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.backgroundColor = .clear
        textField.isBordered = false
        cellView.addSubview(textField)
        cellView.textField = textField

        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 12),
            textField.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -12),
            textField.centerYAnchor.constraint(equalTo: cellView.centerYAnchor)
        ])

        return cellView
    }

    private func installKeyboardMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else {
                return event
            }

            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

            switch key {
            case "q":
                NSApp.terminate(nil)
                return nil
            case "f":
                self.window?.toggleFullScreen(nil)
                return nil
            case "p":
                self.togglePlaylistVisibility()
                return nil
            case "d":
                self.deleteCurrentVideo()
                return nil
            case "s":
                self.saveSnapshot()
                return nil
            case "i":
                self.showMediaInfo()
                return nil
            case "n":
                self.playVideo(at: self.playlist.currentIndex + 1)
                return nil
            case "b":
                self.playVideo(at: self.playlist.currentIndex - 1)
                return nil
            case "r":
                self.player.seek(to: .zero)
                self.player.play()
                return nil
            default:
                break
            }

            switch event.keyCode {
            case 49:
                self.player.rate == 0 ? self.player.play() : self.player.pause()
                return nil
            case 123:
                self.seek(by: -10)
                return nil
            case 124:
                self.seek(by: 10)
                return nil
            default:
                return event
            }
        }
    }

    private func togglePlaylistVisibility() {
        playlistScrollView?.isHidden.toggle()
        if playlistScrollView?.isHidden == false {
            syncPlaylistSelection()
        }
    }

    private func playVideo(at requestedIndex: Int) {
        guard let url = playlist.select(index: requestedIndex) else {
            player.replaceCurrentItem(with: nil)
            updateWindowTitle()
            playlistTableView?.reloadData()
            return
        }

        let asset: AVURLAsset
        if url.isHTTPFamily {
            let loader = RemoteAssetLoader(originalURL: url)
            remoteAssetLoader = loader
            asset = AVURLAsset(url: loader.makeStreamingURL())
            asset.resourceLoader.setDelegate(loader, queue: .main)
        } else {
            remoteAssetLoader = nil
            asset = AVURLAsset(url: url)
        }

        let playerItem = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: playerItem)
        player.play()

        updateWindowTitle()
        syncPlaylistSelection()
    }

    private func syncPlaylistSelection() {
        guard let playlistTableView, !playlist.isEmpty else {
            return
        }

        resizePlaylistTable()
        isProgrammaticSelection = true
        playlistTableView.reloadData()
        playlistTableView.selectRowIndexes(IndexSet(integer: playlist.currentIndex), byExtendingSelection: false)
        playlistTableView.scrollRowToVisible(playlist.currentIndex)
        isProgrammaticSelection = false
    }

    private func updateWindowTitle() {
        guard let window else {
            return
        }

        guard let currentURL = playlist.currentURL else {
            window.title = "No Media"
            return
        }

        window.title = "[\(playlist.currentIndex + 1)/\(playlist.items.count)] \(currentURL.displayName)"
    }

    private func resizePlaylistTable() {
        guard let playlistTableView else {
            return
        }

        let height = CGFloat(max(playlist.items.count, 1)) * 26
        playlistTableView.frame.size = NSSize(width: 300, height: height)
    }

    private func seek(by seconds: Double) {
        let targetTime = CMTimeAdd(player.currentTime(), CMTime(seconds: seconds, preferredTimescale: 600))
        player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func deleteCurrentVideo() {
        guard let currentURL = playlist.currentURL else {
            return
        }

        guard currentURL.isFileURL else {
            presentAlert(title: "Delete Failed", message: "Only local files can be deleted.")
            return
        }

        player.pause()

        do {
            try FileManager.default.removeItem(at: currentURL)
            playlist.removeCurrentItem()
            NSSound.beep()

            if playlist.isEmpty {
                player.replaceCurrentItem(with: nil)
                updateWindowTitle()
                playlistTableView?.reloadData()
            } else {
                playVideo(at: playlist.currentIndex)
            }
        } catch {
            presentAlert(title: "Delete Failed", message: error.localizedDescription)
        }
    }

    private func showMediaInfo() {
        guard let currentItem = player.currentItem, let currentURL = playlist.currentURL else {
            return
        }

        Task { [weak self] in
            guard let self else {
                return
            }

            do {
                let information = try await MediaInformationBuilder.build(for: currentItem.asset, sourceURL: currentURL)
                await self.presentAlert(title: "Media Information", message: information)
            } catch {
                await self.presentAlert(title: "Media Information", message: error.localizedDescription)
            }
        }
    }

    private func saveSnapshot() {
        guard let asset = player.currentItem?.asset else {
            return
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let snapshotTime = player.currentTime()
        let outputURL = makeSnapshotURL()

        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: snapshotTime)]) { [weak self] _, image, _, result, error in
            guard let self else {
                return
            }

            guard result == .succeeded, let image else {
                Task { @MainActor in
                    self.presentAlert(title: "Snapshot Failed", message: error?.localizedDescription ?? "Unable to capture the current frame.")
                }
                return
            }

            guard let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                Task { @MainActor in
                    self.presentAlert(title: "Snapshot Failed", message: "Unable to create the snapshot destination.")
                }
                return
            }

            CGImageDestinationAddImage(destination, image, nil)
            let finalized = CGImageDestinationFinalize(destination)

            Task { @MainActor in
                if finalized {
                    NSSound.beep()
                    print("Saved: \(outputURL.path)")
                } else {
                    self.presentAlert(title: "Snapshot Failed", message: "Unable to finalize the snapshot image.")
                }
            }
        }
    }

    private func makeSnapshotURL() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let fileName = "snapshot_\(formatter.string(from: Date())).png"
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(fileName)
    }

    @MainActor
    private func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

@main
@MainActor
private struct AppMain {
    static func main() {
        do {
            let configuration = try AppConfiguration(arguments: CommandLine.arguments)
            let application = NSApplication.shared
            application.setActivationPolicy(.regular)
            let delegate = PlayerApplication(configuration: configuration)
            application.delegate = delegate
            application.run()
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
