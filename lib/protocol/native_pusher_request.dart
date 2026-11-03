/// Explicit application fields constructed by original macOS native push
/// wrapper 0x10141d1a8. Foundation owns later WebSocket handshake fields.
final class NativePusherRequestPlan {
  NativePusherRequestPlan({required String hostname, required String accessToken,
    required String clientVersion, required int osMajor, required int osMinor,
    required int osPatch}) : urlString = _cString(hostname),
      headers = Map.unmodifiable({
        if (accessToken.isNotEmpty) 'Authorization': 'Bearer ${_cString(accessToken)}',
        'User-Agent': 'music/${_cString(clientVersion)} macos/$osMajor.$osMinor.$osPatch',
      });

  /// Raw input supplied to standard NSURL construction. No query is appended.
  /// Endpoint admission and standard URL normalization belong to the sender.
  final String urlString;
  /// Only original wrapper additions to a newly created mutable URL request.
  /// This does not assert that default Foundation cookies/automatic fields
  /// are absent from the final handshake.
  final Map<String, String> headers;
  String get method => 'GET';

  // The original factory and connect wrapper use stringWithUTF8String:.
  static String _cString(String value) {
    final zero = value.indexOf('\u0000');
    return zero < 0 ? value : value.substring(0, zero);
  }
}
