import AppKit

/// This service has no caller-selected scheme, application, file or command.
/// Launch Services requires this request outside the player's App Sandbox.
private final class SpotifyLinkSettings: NSObject, SpotifyLinkSettingsProtocol {
  private var changing = false

  func setDefaultSpotifyHandler(withReply reply: @escaping (NSError?) -> Void) {
    DispatchQueue.main.async {
      guard !self.changing else {
        reply(NSError(domain: "SpotifyLinkSettings", code: 1,
          userInfo: [NSLocalizedDescriptionKey: "A link settings request is already in progress."]))
        return
      }
      let application = Bundle.main.bundleURL.deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
      guard application.pathExtension == "app",
        Bundle(url: application)?.bundleIdentifier == "dev.meoyawn.spotifyFlutter" else {
        reply(NSError(domain: "SpotifyLinkSettings", code: 2,
          userInfo: [NSLocalizedDescriptionKey: "The Spotify app bundle could not be found."]))
        return
      }
      self.changing = true
      NSWorkspace.shared.setDefaultApplication(at: application, toOpenURLsWithScheme: "spotify") { error in
        reply(error as NSError?)
      }
    }
  }
}

private final class Listener: NSObject, NSXPCListenerDelegate {
  func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
    connection.exportedInterface = NSXPCInterface(with: SpotifyLinkSettingsProtocol.self)
    connection.exportedObject = SpotifyLinkSettings()
    // Each explicit Settings action owns one connection and one service run.
    connection.invalidationHandler = { exit(EXIT_SUCCESS) }
    connection.resume()
    return true
  }
}

let listener = NSXPCListener.service()
private let delegate = Listener()
listener.delegate = delegate
listener.resume()
