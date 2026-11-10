import Cocoa
import FlutterMacOS
import MediaPlayer

@main
class AppDelegate: FlutterAppDelegate {
  private var mediaControls: MacMediaControls?
  private var pendingOpenURL: URL?

  override func application(_ application: NSApplication, open urls: [URL]) {
    guard let url = urls.last else { return }
    if let window = mainFlutterWindow as? MainFlutterWindow {
      window.openURL(url)
    } else {
      pendingOpenURL = url
    }
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    if let url = pendingOpenURL, let window = mainFlutterWindow as? MainFlutterWindow {
      pendingOpenURL = nil
      window.openURL(url)
    }
    if let controller = mainFlutterWindow?.contentViewController as? FlutterViewController {
      mediaControls = MacMediaControls(messenger: controller.engine.binaryMessenger)
    }
    mainFlutterWindow?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if let window = mainFlutterWindow {
      if window.isMiniaturized { window.deminiaturize(nil) }
      window.makeKeyAndOrderFront(nil)
      sender.activate(ignoringOtherApps: true)
    }
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}

/// Apple owns media-key routing and Control Center. Dart supplies all metadata,
/// command availability and player actions; this bridge never changes playback.
private final class MacMediaControls {
  private let channel: FlutterMethodChannel
  private let commands = MPRemoteCommandCenter.shared()
  private let info = MPNowPlayingInfoCenter.default()
  private var targets: [(MPRemoteCommand, Any)] = []
  private var owner: String?
  private var hasItem = false
  private var canPlay = false
  private var canPause = false
  private var canToggle = false
  private var canPrevious = false
  private var canNext = false
  private var itemURI: String?
  private var artworkGeneration = 0
  private var artwork: MPMediaItemArtwork?
  private var terminationObserver: NSObjectProtocol?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "spotify_flutter/desktop_media_controls", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self, let args = call.arguments as? [String: Any],
        let owner = args["owner"] as? String else {
        result(FlutterError(code: "invalid_media_owner", message: "Expected a media-control owner.", details: nil))
        return
      }
      switch call.method {
      case "initialize":
        if self.owner != owner {
          self.clear()
          self.owner = owner
          self.registerCommands()
        }
        result(nil)
      case "update":
        guard self.owner == owner else { result(nil); return }
        self.update(args)
        result(nil)
      case "artwork":
        guard self.owner == owner else { result(nil); return }
        self.updateArtwork(args, result: result)
      case "clear":
        if self.owner == owner { self.clear() }
        result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    }
    terminationObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.clear() }
  }

  private func registerCommands() {
    guard targets.isEmpty else { return }
    for (command, action) in [(commands.playCommand, "play"),
      (commands.pauseCommand, "pause"), (commands.togglePlayPauseCommand, "toggle"),
      (commands.previousTrackCommand, "previous"), (commands.nextTrackCommand, "next")] {
      command.isEnabled = false
      let target = command.addTarget { [weak self] _ in
        guard let self = self else { return .noActionableNowPlayingItem }
        if Thread.isMainThread { return self.deliver(action) }
        return DispatchQueue.main.sync { self.deliver(action) }
      }
      targets.append((command, target))
    }
  }

  private func deliver(_ action: String) -> MPRemoteCommandHandlerStatus {
    guard let owner = owner, hasItem else { return .noActionableNowPlayingItem }
    let allowed: Bool
    switch action {
    case "play": allowed = canPlay
    case "pause": allowed = canPause
    case "toggle": allowed = canToggle
    case "previous": allowed = canPrevious
    case "next": allowed = canNext
    default: return .commandFailed
    }
    guard allowed else { return .commandFailed }
    // Success means accepted for Dart dispatch, not a fabricated player-state
    // transition. The actual controller stream supplies the subsequent update.
    channel.invokeMethod("command", arguments: ["owner": owner, "action": action])
    return .success
  }

  private func update(_ value: [String: Any]) {
    hasItem = value["hasItem"] as? Bool ?? false
    let uri = hasItem ? value["uri"] as? String : nil
    let generation = value["artworkGeneration"] as? Int ?? 0
    if uri != itemURI || generation != artworkGeneration || !hasItem {
      // Clear the previous cover in the same update as the new track, before
      // the independently asynchronous Dart image loader can complete.
      artwork = nil
      itemURI = uri
      artworkGeneration = generation
    }
    canPlay = hasItem && (value["canPlay"] as? Bool ?? false)
    canPause = hasItem && (value["canPause"] as? Bool ?? false)
    canToggle = hasItem && (value["canToggle"] as? Bool ?? false)
    canPrevious = hasItem && (value["canPrevious"] as? Bool ?? false)
    canNext = hasItem && (value["canNext"] as? Bool ?? false)
    commands.playCommand.isEnabled = canPlay
    commands.pauseCommand.isEnabled = canPause
    commands.togglePlayPauseCommand.isEnabled = canToggle
    commands.previousTrackCommand.isEnabled = canPrevious
    commands.nextTrackCommand.isEnabled = canNext
    guard hasItem else {
      info.nowPlayingInfo = nil
      info.playbackState = .stopped
      return
    }
    var metadata: [String: Any] = [:]
    for (field, key) in [("title", MPMediaItemPropertyTitle),
      ("artist", MPMediaItemPropertyArtist), ("album", MPMediaItemPropertyAlbumTitle),
      ("uri", MPNowPlayingInfoPropertyExternalContentIdentifier)] {
      if let text = value[field] as? String, !text.isEmpty { metadata[key] = text }
    }
    if let duration = value["durationSeconds"] as? Double, duration.isFinite, duration >= 0 {
      metadata[MPMediaItemPropertyPlaybackDuration] = duration
    }
    if let elapsed = value["elapsedSeconds"] as? Double, elapsed.isFinite, elapsed >= 0 {
      metadata[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
    }
    if let rate = value["playbackRate"] as? Double, rate.isFinite, rate >= 0 {
      metadata[MPNowPlayingInfoPropertyPlaybackRate] = rate
    }
    metadata[MPNowPlayingInfoPropertyMediaType] = (value["mediaType"] as? String) == "video"
      ? MPNowPlayingInfoMediaType.video.rawValue : MPNowPlayingInfoMediaType.audio.rawValue
    if let artwork = artwork { metadata[MPMediaItemPropertyArtwork] = artwork }
    info.nowPlayingInfo = metadata
    switch value["playbackState"] as? String {
    case "playing": info.playbackState = .playing
    case "paused": info.playbackState = .paused
    default: info.playbackState = .stopped
    }
  }

  private func updateArtwork(_ value: [String: Any], result: FlutterResult) {
    guard hasItem, let uri = value["uri"] as? String, uri == itemURI,
      let generation = value["artworkGeneration"] as? Int, generation == artworkGeneration else {
      result(nil)
      return
    }
    guard let bytes = value["bytes"] as? FlutterStandardTypedData,
      let image = NSImage(data: bytes.data), image.isValid,
      image.size.width.isFinite, image.size.height.isFinite,
      image.size.width > 0, image.size.height > 0 else {
      result(FlutterError(code: "invalid_artwork", message: "Now Playing artwork could not be decoded.", details: nil))
      return
    }
    // AppKit supplies the standard image decoder; no URL, fetching or player
    // decisions enter this bridge. Retain only the current track's artwork.
    let cover = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    artwork = cover
    if var metadata = info.nowPlayingInfo {
      metadata[MPMediaItemPropertyArtwork] = cover
      info.nowPlayingInfo = metadata
    }
    result(nil)
  }

  private func clear() {
    for (command, target) in targets {
      command.removeTarget(target)
      command.isEnabled = false
    }
    targets.removeAll()
    owner = nil
    hasItem = false
    canPlay = false
    canPause = false
    canToggle = false
    canPrevious = false
    canNext = false
    itemURI = nil
    artworkGeneration = 0
    artwork = nil
    info.nowPlayingInfo = nil
    info.playbackState = .stopped
  }

  deinit {
    if let observer = terminationObserver { NotificationCenter.default.removeObserver(observer) }
    clear()
  }
}
