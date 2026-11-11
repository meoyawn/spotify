import Foundation

@objc(SpotifyLinkSettingsProtocol) protocol SpotifyLinkSettingsProtocol {
  func setDefaultSpotifyHandler(withReply reply: @escaping (NSError?) -> Void)
}
