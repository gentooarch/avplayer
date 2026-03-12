// Build example:
// swiftc -O -framework Cocoa -framework AVFoundation -framework AVKit -framework UniformTypeIdentifiers main.swift -o localplayer

import AVFoundation
import AVKit
import Cocoa
import CoreMedia
import Foundation
import UniformTypeIdentifiers

private enum ExitCode: Int32 {
    case success = 0
    case usage = 64
    case unavailable = 69
    case software = 70
}

private enum Defaults {
    static let initialWindowRect = NSRect(x: 0, y: 0, width: 960, height: 540)
    static let minimumContentSize = NSSize(width: 480, height: 270)
    static let seekStepSeconds = 10.0
    static let timeScale: CMTimeScale = 600
    static let windowStyle: NSWindow.StyleMask = [
        .titled,
        .closable,
        .miniaturizable,
        .resizable
    ]
}

private enum AppState {
    static var exitCode: ExitCode = .success
}

private enum PlayerError: LocalizedError {
    case missingMediaPath
    case invalidOption(String)
    case missingOptionValue(String)
    case invalidVolume(String)
    case invalidStartTime(String)
    case tooManyPaths
    case unsupportedURL(String)
    case fileNotFound(String)
    case directoryNotSupported(String)
    case unreadableFile(String)
    case unsupportedFileType(String)
    case playerFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingMediaPath:
            return "Missing local media path."
        case let .invalidOption(option):
            return "Unknown option: \(option)"
        case let .missingOptionValue(option):
            return "Missing value for option: \(option)"
        case let .invalidVolume(value):
            return "Invalid volume '\(value)'. Expected a number between 0 and 1."
        case let .invalidStartTime(value):
            return "Invalid start time '\(value)'. Expected a non-negative number of seconds."
        case .tooManyPaths:
            return "Only one media file can be played at a time."
        case let .unsupportedURL(value):
            return "Only local file paths or file:// URLs are supported: \(value)"
        case let .fileNotFound(path):
            return "File does not exist: \(path)"
        case let .directoryNotSupported(path):
            return "Directories are not supported: \(path)"
        case let .unreadableFile(path):
            return "File is not readable: \(path)"
        case let .unsupportedFileType(path):
            return "Unsupported media type: \(path)"
        case let .playerFailed(message):
            return "Playback failed: \(message)"
        }
    }
}

private struct CLIOptions {
    let mediaPath: String
    let autoplay: Bool
    let loopPlayback: Bool
    let quitWhenFinished: Bool
    let muted: Bool
    let volume: Float
    let startAtSeconds: Double

    static func usage(programName: String) -> String {
        """
        Usage:
          \(programName) [options] <local-media-file>

        Options:
          --loop                 Restart automatically when playback reaches the end.
          --no-autoplay          Open the window without starting playback.
          --quit-when-finished   Exit the app when playback completes.
          --mute                 Start muted.
          --volume <0...1>       Initial output volume. Default: 1.0
          --start-at <seconds>   Seek to a start position before playback begins.
          -h, --help             Show this help message.

        Notes:
          - Only local files are supported.
          - This player is intentionally event-driven for low energy use:
            no polling timers, no periodic observers, and one-time window sizing.
        """
    }
}

private enum CLIParser {
    static func parse(arguments: [String]) throws -> CLIOptions? {
        var autoplay = true
        var loopPlayback = false
        var quitWhenFinished = false
        var muted = false
        var volume: Float = 1.0
        var startAtSeconds = 0.0
        var mediaPath: String?
        var index = 0
        var stopParsingOptions = false

        while index < arguments.count {
            let argument = arguments[index]

            if stopParsingOptions {
                if mediaPath == nil {
                    mediaPath = argument
                } else {
                    throw PlayerError.tooManyPaths
                }
                index += 1
                continue
            }

            switch argument {
            case "-h", "--help":
                return nil
            case "--":
                stopParsingOptions = true
            case "--loop":
                loopPlayback = true
            case "--no-autoplay":
                autoplay = false
            case "--quit-when-finished":
                quitWhenFinished = true
            case "--mute":
                muted = true
            case "--volume":
                let value = try nextValue(after: &index, in: arguments, option: argument)
                guard let parsed = Float(value), (0...1).contains(parsed) else {
                    throw PlayerError.invalidVolume(value)
                }
                volume = parsed
            case "--start-at":
                let value = try nextValue(after: &index, in: arguments, option: argument)
                guard let parsed = Double(value), parsed >= 0 else {
                    throw PlayerError.invalidStartTime(value)
                }
                startAtSeconds = parsed
            default:
                if argument.hasPrefix("-") {
                    throw PlayerError.invalidOption(argument)
                }
                if mediaPath == nil {
                    mediaPath = argument
                } else {
                    throw PlayerError.tooManyPaths
                }
            }

            index += 1
        }

        guard let mediaPath else {
            throw PlayerError.missingMediaPath
        }

        return CLIOptions(
            mediaPath: mediaPath,
            autoplay: autoplay,
            loopPlayback: loopPlayback,
            quitWhenFinished: quitWhenFinished,
            muted: muted,
            volume: volume,
            startAtSeconds: startAtSeconds
        )
    }

    private static func nextValue(
        after index: inout Int,
        in arguments: [String],
        option: String
    ) throws -> String {
        let nextIndex = index + 1
        guard nextIndex < arguments.count else {
            throw PlayerError.missingOptionValue(option)
        }
        index = nextIndex
        return arguments[nextIndex]
    }
}

private struct MediaLocator {
    static func resolve(from rawPath: String) throws -> URL {
        let url: URL
        if rawPath.contains("://") {
            guard let parsed = URL(string: rawPath), parsed.isFileURL else {
                throw PlayerError.unsupportedURL(rawPath)
            }
            url = parsed
        } else {
            let expandedPath = (rawPath as NSString).expandingTildeInPath
            if expandedPath.hasPrefix("/") {
                url = URL(fileURLWithPath: expandedPath)
            } else {
                let cwd = FileManager.default.currentDirectoryPath
                url = URL(fileURLWithPath: cwd).appendingPathComponent(expandedPath)
            }
        }

        let standardizedURL = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        let path = standardizedURL.path

        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw PlayerError.fileNotFound(path)
        }
        guard !isDirectory.boolValue else {
            throw PlayerError.directoryNotSupported(path)
        }
        guard FileManager.default.isReadableFile(atPath: path) else {
            throw PlayerError.unreadableFile(path)
        }
        guard isLikelySupportedMedia(url: standardizedURL) else {
            throw PlayerError.unsupportedFileType(path)
        }

        return standardizedURL
    }

    private static func isLikelySupportedMedia(url: URL) -> Bool {
        let pathExtension = url.pathExtension
        guard !pathExtension.isEmpty else {
            return true
        }
        guard let type = UTType(filenameExtension: pathExtension) else {
            return true
        }
        return type.conforms(to: .movie) || type.conforms(to: .audio) || type.conforms(to: .mpeg4Movie)
    }
}

private enum StandardIO {
    static func writeLine(_ message: String) {
        write(message + "\n", to: FileHandle.standardOutput)
    }

    static func writeErrorLine(_ message: String) {
        write(message + "\n", to: FileHandle.standardError)
    }

    private static func write(_ message: String, to handle: FileHandle) {
        guard let data = message.data(using: .utf8) else { return }
        try? handle.write(contentsOf: data)
    }
}

private final class PlaybackSession {
    let player: AVPlayer

    var onPresentationSizeAvailable: ((CGSize) -> Void)?
    var onPlaybackFailure: ((String) -> Void)?
    var onPlaybackFinished: (() -> Void)?

    private let options: CLIOptions
    private let item: AVPlayerItem

    private var itemStatusObservation: NSKeyValueObservation?
    private var presentationSizeObservation: NSKeyValueObservation?
    private var itemEndObserver: NSObjectProtocol?

    private var didPreparePlayback = false
    private var didPublishPresentationSize = false

    init(options: CLIOptions, mediaURL: URL) {
        self.options = options

        let asset = AVURLAsset(
            url: mediaURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: false]
        )

        let item = AVPlayerItem(asset: asset)
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        item.preferredForwardBufferDuration = 0

        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = options.loopPlayback ? .none : .pause
        player.automaticallyWaitsToMinimizeStalling = true
        player.allowsExternalPlayback = false
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.isMuted = options.muted
        player.volume = options.volume

        self.item = item
        self.player = player

        beginObserving()
    }

    deinit {
        tearDown()
    }

    func playIfNeeded() {
        guard options.autoplay else { return }
        player.play()
    }

    func togglePlayback() {
        if player.timeControlStatus == .paused {
            player.play()
        } else {
            player.pause()
        }
    }

    func pause() {
        player.pause()
    }

    func toggleMute() {
        player.isMuted.toggle()
    }

    func seek(by deltaSeconds: Double) {
        let currentSeconds = player.currentTime().seconds
        let safeCurrentSeconds = currentSeconds.isFinite ? currentSeconds : 0
        let targetSeconds = max(0, safeCurrentSeconds + deltaSeconds)
        let target = CMTime(seconds: targetSeconds, preferredTimescale: Defaults.timeScale)

        player.seek(
            to: target,
            toleranceBefore: .positiveInfinity,
            toleranceAfter: .positiveInfinity
        )
    }

    private func beginObserving() {
        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            self?.handleItemStatus(item.status)
        }

        presentationSizeObservation = item.observe(\.presentationSize, options: [.new]) { [weak self] item, _ in
            self?.handlePresentationSize(item.presentationSize)
        }

        itemEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.handleItemEnded()
        }
    }

    private func handleItemStatus(_ status: AVPlayerItem.Status) {
        switch status {
        case .readyToPlay:
            preparePlaybackIfNeeded()
        case .failed:
            let message = item.error?.localizedDescription ?? "Unknown AVPlayerItem failure."
            onPlaybackFailure?(message)
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    private func preparePlaybackIfNeeded() {
        guard !didPreparePlayback else { return }
        didPreparePlayback = true

        let startTime = options.startAtSeconds
        guard startTime > 0 else {
            playIfNeeded()
            return
        }

        let target = CMTime(seconds: startTime, preferredTimescale: Defaults.timeScale)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            self?.playIfNeeded()
        }
    }

    private func handlePresentationSize(_ size: CGSize) {
        guard !didPublishPresentationSize, size.width > 0, size.height > 0 else {
            return
        }

        didPublishPresentationSize = true
        player.preventsDisplaySleepDuringVideoPlayback = true
        onPresentationSizeAvailable?(size)

        // Window sizing only needs the first stable presentation size.
        presentationSizeObservation = nil
    }

    private func handleItemEnded() {
        if options.loopPlayback {
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                self?.player.play()
            }
            return
        }

        onPlaybackFinished?()
    }

    private func tearDown() {
        if let itemEndObserver {
            NotificationCenter.default.removeObserver(itemEndObserver)
        }
        itemEndObserver = nil
        itemStatusObservation = nil
        presentationSizeObservation = nil
        player.pause()
    }
}

private final class PlayerWindowController: NSWindowController, NSWindowDelegate {
    private let playerView = AVPlayerView(frame: .zero)
    private weak var session: PlaybackSession?
    private var didResizeWindow = false

    init(title: String, session: PlaybackSession) {
        self.session = session
        super.init(window: Self.makeWindow(title: title))
        configureWindow()
        configureContentView()
        playerView.player = session.player
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func applyPreferredWindowSize(for presentationSize: CGSize) {
        guard !didResizeWindow, let window, presentationSize.width > 0, presentationSize.height > 0 else {
            return
        }

        didResizeWindow = true

        let contentSize = fittedContentSize(for: presentationSize, in: window)
        let targetContentRect = NSRect(origin: .zero, size: contentSize)
        let targetFrame = window.frameRect(forContentRect: targetContentRect)
        let currentFrame = window.frame
        let newOrigin = NSPoint(
            x: currentFrame.midX - (targetFrame.width / 2),
            y: currentFrame.midY - (targetFrame.height / 2)
        )
        let newFrame = NSRect(origin: newOrigin, size: targetFrame.size)

        window.setFrame(newFrame, display: true, animate: false)
    }

    func windowWillClose(_ notification: Notification) {
        session?.pause()
    }

    private static func makeWindow(title: String) -> NSWindow {
        let window = NSWindow(
            contentRect: Defaults.initialWindowRect,
            styleMask: Defaults.windowStyle,
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.collectionBehavior = [.fullScreenPrimary]
        window.backgroundColor = .black
        return window
    }

    private func configureWindow() {
        guard let window else { return }
        window.delegate = self
        window.center()
        window.minSize = Defaults.minimumContentSize
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.acceptsMouseMovedEvents = false
        window.titleVisibility = .visible
    }

    private func configureContentView() {
        guard let window else { return }

        let containerView = NSView(frame: Defaults.initialWindowRect)
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.black.cgColor

        playerView.translatesAutoresizingMaskIntoConstraints = false
        playerView.controlsStyle = .floating
        playerView.videoGravity = .resizeAspect
        playerView.allowsPictureInPicturePlayback = false
        playerView.showsFullScreenToggleButton = true

        containerView.addSubview(playerView)
        NSLayoutConstraint.activate([
            playerView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            playerView.topAnchor.constraint(equalTo: containerView.topAnchor),
            playerView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
        ])

        window.contentView = containerView
    }

    private func fittedContentSize(for presentationSize: CGSize, in window: NSWindow) -> NSSize {
        let visibleFrame = window.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let maxWidth = max(Defaults.minimumContentSize.width, visibleFrame.width * 0.85)
        let maxHeight = max(Defaults.minimumContentSize.height, visibleFrame.height * 0.85)

        var width = presentationSize.width
        var height = presentationSize.height

        let scale = min(maxWidth / width, maxHeight / height, 1.0)
        width *= scale
        height *= scale

        let aspectRatio = width / height
        if width < Defaults.minimumContentSize.width {
            width = Defaults.minimumContentSize.width
            height = width / aspectRatio
        }
        if height < Defaults.minimumContentSize.height {
            height = Defaults.minimumContentSize.height
            width = height * aspectRatio
        }

        return NSSize(width: round(width), height: round(height))
    }
}

private final class ApplicationCoordinator: NSObject, NSApplicationDelegate {
    private let options: CLIOptions
    private let mediaURL: URL

    private var session: PlaybackSession?
    private var windowController: PlayerWindowController?

    init(options: CLIOptions, mediaURL: URL) {
        self.options = options
        self.mediaURL = mediaURL
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMainMenu()

        let session = PlaybackSession(options: options, mediaURL: mediaURL)
        let windowController = PlayerWindowController(title: mediaURL.lastPathComponent, session: session)

        session.onPresentationSizeAvailable = { [weak windowController] size in
            windowController?.applyPreferredWindowSize(for: size)
        }

        session.onPlaybackFailure = { message in
            AppState.exitCode = .software
            StandardIO.writeErrorLine(PlayerError.playerFailed(message).localizedDescription)
            NSApp.terminate(nil)
        }

        session.onPlaybackFinished = { [weak self] in
            guard let self = self, self.options.quitWhenFinished else { return }
            NSApp.terminate(nil)
        }

        self.session = session
        self.windowController = windowController

        windowController.show()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @objc
    private func togglePlayback(_ sender: Any?) {
        session?.togglePlayback()
    }

    @objc
    private func toggleMute(_ sender: Any?) {
        session?.toggleMute()
    }

    @objc
    private func seekBackward(_ sender: Any?) {
        session?.seek(by: -Defaults.seekStepSeconds)
    }

    @objc
    private func seekForward(_ sender: Any?) {
        session?.seek(by: Defaults.seekStepSeconds)
    }

    private func buildMainMenu() -> NSMenu {
        let menu = NSMenu()

        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = buildApplicationMenu()
        menu.addItem(appMenuItem)

        let playbackMenuItem = NSMenuItem()
        playbackMenuItem.submenu = buildPlaybackMenu()
        menu.addItem(playbackMenuItem)

        return menu
    }

    private func buildApplicationMenu() -> NSMenu {
        let menu = NSMenu(title: "Application")
        let appName = ProcessInfo.processInfo.processName

        let quitItem = NSMenuItem(
            title: "Quit \(appName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = [.command]
        menu.addItem(quitItem)

        return menu
    }

    private func buildPlaybackMenu() -> NSMenu {
        let menu = NSMenu(title: "Playback")

        let playPauseItem = NSMenuItem(
            title: "Play/Pause",
            action: #selector(togglePlayback(_:)),
            keyEquivalent: " "
        )
        playPauseItem.target = self
        playPauseItem.keyEquivalentModifierMask = []
        menu.addItem(playPauseItem)

        let muteItem = NSMenuItem(
            title: "Mute/Unmute",
            action: #selector(toggleMute(_:)),
            keyEquivalent: "m"
        )
        muteItem.target = self
        muteItem.keyEquivalentModifierMask = []
        menu.addItem(muteItem)

        let seekBackwardItem = NSMenuItem(
            title: "Back 10 Seconds",
            action: #selector(seekBackward(_:)),
            keyEquivalent: "["
        )
        seekBackwardItem.target = self
        seekBackwardItem.keyEquivalentModifierMask = []
        menu.addItem(seekBackwardItem)

        let seekForwardItem = NSMenuItem(
            title: "Forward 10 Seconds",
            action: #selector(seekForward(_:)),
            keyEquivalent: "]"
        )
        seekForwardItem.target = self
        seekForwardItem.keyEquivalentModifierMask = []
        menu.addItem(seekForwardItem)

        return menu
    }
}

private func exitCode(for error: PlayerError) -> ExitCode {
    switch error {
    case .missingMediaPath,
         .invalidOption,
         .missingOptionValue,
         .invalidVolume,
         .invalidStartTime,
         .tooManyPaths:
        return .usage
    case .unsupportedURL,
         .fileNotFound,
         .directoryNotSupported,
         .unreadableFile,
         .unsupportedFileType:
        return .unavailable
    case .playerFailed:
        return .software
    }
}

do {
    let programName = (CommandLine.arguments.first as NSString?)?.lastPathComponent ?? "localplayer"
    let arguments = Array(CommandLine.arguments.dropFirst())

    guard let options = try CLIParser.parse(arguments: arguments) else {
        StandardIO.writeLine(CLIOptions.usage(programName: programName))
        Foundation.exit(ExitCode.success.rawValue)
    }

    let mediaURL = try MediaLocator.resolve(from: options.mediaPath)

    let application = NSApplication.shared
    application.setActivationPolicy(.regular)

    let coordinator = ApplicationCoordinator(options: options, mediaURL: mediaURL)
    application.delegate = coordinator
    application.run()

    Foundation.exit(AppState.exitCode.rawValue)
} catch let error as PlayerError {
    StandardIO.writeErrorLine(error.localizedDescription)
    StandardIO.writeErrorLine("")
    StandardIO.writeErrorLine(CLIOptions.usage(programName: ProcessInfo.processInfo.processName))
    Foundation.exit(exitCode(for: error).rawValue)
} catch {
    StandardIO.writeErrorLine(error.localizedDescription)
    Foundation.exit(ExitCode.software.rawValue)
}
