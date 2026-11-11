import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var desktopChannel: FlutterMethodChannel?
  private var linkChannel: FlutterMethodChannel?
  private var linksReady = false
  private var pendingOpenURL: String?
  private var foundationWebSockets: FoundationWebSockets?
  private var linkSettingsConnection: NSXPCConnection?
  private var linkSettingsReply: FlutterResult?

  private func isDefaultSpotifyHandler() -> Bool {
    let handler = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "spotify:")!)
    guard let handler = handler, let identifier = Bundle.main.bundleIdentifier else { return false }
    return Bundle(url: handler)?.bundleIdentifier == identifier
  }

  private func finishLinkSettings(_ connection: NSXPCConnection, error: NSError?) {
    guard linkSettingsConnection === connection else { return }
    let reply = linkSettingsReply
    linkSettingsConnection = nil
    linkSettingsReply = nil
    connection.invalidate()
    if let error = error {
      let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
      NSLog("Spotify link settings failed: %@ %ld (underlying %@ %ld)",
        error.domain, error.code, underlying?.domain ?? "", underlying?.code ?? 0)
      reply?(FlutterError(code: "default_handler_failed", message: error.localizedDescription,
        details: ["domain": error.domain, "code": error.code,
          "underlyingDomain": underlying?.domain ?? "", "underlyingCode": underlying?.code ?? 0]))
    } else if isDefaultSpotifyHandler() {
      reply?(nil)
    } else {
      reply?(FlutterError(code: "default_handler_unchanged",
        message: "Spotify wasn’t selected as the default app.", details: nil))
    }
  }

  private func setDefaultSpotifyHandler(_ result: @escaping FlutterResult) {
    guard linkSettingsConnection == nil else {
      result(FlutterError(code: "default_handler_busy", message: "A macOS confirmation is already open.", details: nil))
      return
    }
    let service = "dev.meoyawn.spotifyFlutter.LinkSettings"
    let url = Bundle.main.bundleURL.appendingPathComponent("Contents/XPCServices/SpotifyLinkSettings.xpc")
    guard Bundle(url: url)?.bundleIdentifier == service else {
      result(FlutterError(code: "default_handler_helper_missing", message: "Link settings are missing from this build.", details: nil))
      return
    }
    let connection = NSXPCConnection(serviceName: service)
    linkSettingsConnection = connection
    linkSettingsReply = result
    connection.remoteObjectInterface = NSXPCInterface(with: SpotifyLinkSettingsProtocol.self)
    connection.interruptionHandler = { [weak self, weak connection] in
      DispatchQueue.main.async {
        guard let connection = connection else { return }
        self?.finishLinkSettings(connection, error: NSError(domain: NSCocoaErrorDomain, code: NSXPCConnectionInterrupted))
      }
    }
    connection.invalidationHandler = { [weak self, weak connection] in
      DispatchQueue.main.async {
        guard let connection = connection else { return }
        self?.finishLinkSettings(connection, error: NSError(domain: NSCocoaErrorDomain, code: NSXPCConnectionInvalid))
      }
    }
    connection.resume()
    guard let remote = connection.remoteObjectProxyWithErrorHandler({ [weak self, weak connection] error in
      DispatchQueue.main.async {
        guard let connection = connection else { return }
        self?.finishLinkSettings(connection, error: error as NSError)
      }
    }) as? SpotifyLinkSettingsProtocol else {
      finishLinkSettings(connection, error: NSError(domain: NSCocoaErrorDomain, code: NSXPCConnectionInvalid))
      return
    }
    remote.setDefaultSpotifyHandler { [weak self, weak connection] error in
      DispatchQueue.main.async {
        guard let connection = connection else { return }
        self?.finishLinkSettings(connection, error: error)
      }
    }
  }

  func openURL(_ url: URL) {
    if linksReady {
      linkChannel?.invokeMethod("openUrl", arguments: url.absoluteString)
    } else {
      pendingOpenURL = url.absoluteString
    }
    if isMiniaturized { deminiaturize(nil) }
    makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  override func close() {
    // Keep the Flutter view, Dart session and audio output attached while the
    // player is in the background. Quit remains NSApplication's terminate action.
    orderOut(nil)
  }

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.title = "Spotify"
    self.styleMask.insert(.fullSizeContentView)
    self.titleVisibility = .hidden
    self.titlebarAppearsTransparent = true
    self.titlebarSeparatorStyle = .none
    self.isMovableByWindowBackground = true
    self.backgroundColor = .black
    let savedFrame = "SpotifyFlutterMainWindow"
    if !self.setFrameUsingName(savedFrame), let available = self.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
      self.setContentSize(NSSize(width: min(1400, available.width), height: min(900, available.height - 40)))
      self.center()
    }
    self.setFrameAutosaveName(savedFrame)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let links = FlutterMethodChannel(name: "spotify_flutter/desktop_links",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    links.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(nil); return }
      switch call.method {
      case "takePendingUrl":
        self.linksReady = true
        let pending = self.pendingOpenURL
        self.pendingOpenURL = nil
        result(pending)
      case "stop":
        self.linksReady = false
        result(nil)
      case "isDefaultHandler":
        result(self.isDefaultSpotifyHandler())
      case "setDefaultHandler":
        self.setDefaultSpotifyHandler(result)
      case "cancelDefaultHandlerRequest":
        if let connection = self.linkSettingsConnection {
          self.finishLinkSettings(connection, error: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        }
        result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    }
    linkChannel = links

    let channel = FlutterMethodChannel(name: "spotify_flutter/desktop_host",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "appleLanguages":
        result(UserDefaults.standard.stringArray(forKey: "AppleLanguages") ?? [])
      case "openExternalUrl":
        guard let text = call.arguments as? String, let url = URL(string: text),
          url.scheme == "https" || url.scheme == "http" else {
          result(FlutterError(code: "invalid_url", message: "Expected an HTTP or HTTPS URL.", details: nil))
          return
        }
        result(NSWorkspace.shared.open(url))
      case "showWindow":
        if let window = self {
          if window.isMiniaturized { window.deminiaturize(nil) }
          window.makeKeyAndOrderFront(nil)
          NSApp.activate(ignoringOtherApps: true)
        }
        result(nil)
      case "closeWindow":
        self?.performClose(nil)
        result(nil)
      case "startWindowDrag":
        // The Dart header marks only empty areas; AppKit owns the movement.
        // Keep native controls, fullscreen transitions and drag constraints.
        result(nil)
        DispatchQueue.main.async { [weak self] in
          guard let window = self, !window.styleMask.contains(.fullScreen),
            let event = window.currentEvent else { return }
          if event.type == .leftMouseDown || event.type == .leftMouseDragged {
            window.performDrag(with: event)
          }
        }
      case "quit":
        result(nil)
        NSApp.terminate(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    desktopChannel = channel
    foundationWebSockets = FoundationWebSockets(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}

// Standard Foundation transport only. Dart owns destinations, application
// headers, message contents, session state, ping cadence and reconnect policy.
private final class FoundationWebSockets {
  private let channel: FlutterMethodChannel
  private var sockets: [Int: FoundationSocket] = [:]

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "spotify_flutter/foundation_web_socket", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self, let args = call.arguments as? [String: Any],
        let id = args["id"] as? Int else {
        result(FlutterError(code: "invalid_socket", message: "Expected a socket identifier.", details: nil))
        return
      }
      switch call.method {
      case "open":
        guard self.sockets[id] == nil, let rawUrl = args["url"] as? String,
          let url = URL(string: rawUrl), let headers = args["headers"] as? [[String]],
          headers.allSatisfy({ $0.count == 2 }),
          url.scheme == "wss" || (url.scheme == "ws" && ["localhost", "127.0.0.1", "::1"].contains(url.host ?? "")) else {
          result(FlutterError(code: "invalid_socket", message: "Expected an admitted WebSocket URL and headers.", details: nil))
          return
        }
        var request = URLRequest(url: url)
        for header in headers { request.addValue(header[1], forHTTPHeaderField: header[0]) }
        let socket = FoundationSocket(id: id) { [weak self] event, terminal in
          DispatchQueue.main.async {
            guard let self = self else { return }
            self.channel.invokeMethod("event", arguments: event)
            if terminal { self.sockets.removeValue(forKey: id) }
          }
        }
        self.sockets[id] = socket
        socket.open(request)
        result(nil)
      case "send":
        guard let socket = self.sockets[id], let type = args["type"] as? String else {
          result(FlutterError(code: "socket_closed", message: "WebSocket is closed.", details: nil))
          return
        }
        let message: URLSessionWebSocketTask.Message
        if type == "text", let text = args["data"] as? String { message = .string(text) }
        else if type == "binary", let bytes = args["data"] as? FlutterStandardTypedData { message = .data(bytes.data) }
        else {
          result(FlutterError(code: "invalid_message", message: "Expected text or binary data.", details: nil))
          return
        }
        socket.send(message, result: result)
      case "ping":
        guard let socket = self.sockets[id] else {
          result(FlutterError(code: "socket_closed", message: "WebSocket is closed.", details: nil))
          return
        }
        socket.ping(result: result)
      case "close":
        self.sockets.removeValue(forKey: id)?.close()
        result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }
}

private final class FoundationSocket: NSObject, URLSessionWebSocketDelegate {
  private let id: Int
  private let emit: ([String: Any], Bool) -> Void
  private var session: URLSession?
  private var task: URLSessionWebSocketTask?
  private var ended = false

  init(id: Int, emit: @escaping ([String: Any], Bool) -> Void) {
    self.id = id
    self.emit = emit
  }

  func open(_ request: URLRequest) {
    let session = URLSession(configuration: .default, delegate: self, delegateQueue: OperationQueue())
    self.session = session
    let task = session.webSocketTask(with: request)
    self.task = task
    task.resume()
    receive()
  }

  private func receive() {
    task?.receive { [weak self] received in
      DispatchQueue.main.async {
        guard let self = self, !self.ended else { return }
        switch received {
        case .success(.string(let text)): self.emit(["id": self.id, "type": "text", "data": text], false)
        case .success(.data(let bytes)):
          self.emit(["id": self.id, "type": "binary", "data": FlutterStandardTypedData(bytes: bytes)], false)
        case .failure(let error): self.finish(error)
        @unknown default: break
        }
        if !self.ended { self.receive() }
      }
    }
  }

  func send(_ message: URLSessionWebSocketTask.Message, result: @escaping FlutterResult) {
    guard let task = task, !ended else {
      result(FlutterError(code: "socket_closed", message: "WebSocket is closed.", details: nil))
      return
    }
    task.send(message) { error in
      DispatchQueue.main.async {
        result(error.map { FlutterError(code: "socket_send", message: $0.localizedDescription, details: nil) })
      }
    }
  }

  func ping(result: @escaping FlutterResult) {
    guard let task = task, !ended else {
      result(FlutterError(code: "socket_closed", message: "WebSocket is closed.", details: nil))
      return
    }
    task.sendPing { error in
      DispatchQueue.main.async {
        result(error.map { FlutterError(code: "socket_ping", message: $0.localizedDescription, details: nil) })
      }
    }
  }

  func close() {
    guard !ended else { return }
    task?.cancel(with: .normalClosure, reason: nil)
    finish(nil)
  }

  private func finish(_ error: Error?) {
    guard !ended else { return }
    ended = true
    if let error = error as NSError? {
      emit(["id": id, "type": "error", "code": error.code, "message": error.localizedDescription], true)
    } else { emit(["id": id, "type": "closed"], true) }
    task = nil
    session?.invalidateAndCancel()
    session = nil
  }

  func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
    DispatchQueue.main.async { [weak self] in self?.finish(nil) }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask,
    didCompleteWithError error: Error?) {
    if let error = error { DispatchQueue.main.async { [weak self] in self?.finish(error) } }
  }
}
