import 'esperanto.dart';
import 'generated/es_desktop_version.pb.dart' as proto;

/// Compatibility identity observed in the installed arm64 reference build.
/// Application display/versioning is separate from this protocol identity.
class DesktopIdentity {
  const DesktopIdentity();

  static const fullVersion = '1.3.6.1921.g7086c071a617';
  static const appVersion = '1.3.6.1921';
  static const appPlatform = 'OSX_ARM64';
  static const numericVersion = 130601921;
  static const cefVersion = 'cef_151.3.18+gbeff58d+chromium-151.0.7922.138';
  /// Original descriptor 0x102808838 decoded by 0x101d84a58 after startup
  /// 0x101d845a0; scopes are the ordered output of 0x101d84484.
  static const accountsClientId = '65b708073fc0480ea92a077233ca87bd';
  static const accountsScopes = <String>[
    'app-remote-control', 'playlist-modify', 'playlist-modify-private',
    'playlist-modify-public', 'playlist-read', 'playlist-read-collaborative',
    'playlist-read-private', 'streaming', 'transfer-auth-session',
    'sts-content-management', 'ugc-image-upload', 'user-follow-modify',
    'user-follow-read', 'user-library-modify', 'user-library-read', 'user-modify',
    'user-modify-playback-state', 'user-modify-private', 'user-personalized',
    'user-read-birthdate', 'user-read-currently-playing', 'user-read-email',
    'user-read-play-history', 'user-read-playback-position', 'user-read-playback-state',
    'user-read-private', 'user-read-recently-played', 'user-top-read',
  ];
  static const rendererUserAgent =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/151.0.7922.138 Spotify/1.3.6.1921 Safari/537.36';

  /// Root configuration 0x100061f64 supplies numericVersion and hw.model;
  /// connectivity scope 0x1017bf9b4 supplies this distinct native identity.
  static String nativeUserAgent(String hardwareModel, {String userAgentOverride = ''}) {
    if (userAgentOverride.isNotEmpty) return userAgentOverride;
    // The native default uses printf %s for hw.model, while a nonempty
    // configuration override is copied as a length-bearing std::string.
    final zero = hardwareModel.indexOf('\u0000');
    final model = zero < 0 ? hardwareModel : hardwareModel.substring(0, zero);
    return 'Spotify/$numericVersion $appPlatform/0 ($model)';
  }

  proto.VersionInfoResponse versionInfo() => proto.VersionInfoResponse(
    version: fullVersion,
    buildType: proto.BuildType.BUILD_TYPE_RELEASE,
    platform: proto.Platform.PLATFORM_OSX_ARM64,
    cefVersion: cefVersion,
    cefRuntime: proto.CefRuntime.CEF_RUNTIME_CHROME,
    buildConfiguration: proto.BuildConfiguration.BUILD_CONFIG_STANDARD,
  );
}

/// Pure Dart replacement for the original local metadata handler.
class DesktopVersionService {
  const DesktopVersionService(this.identity);
  final DesktopIdentity identity;
  static const id = 'spotify.desktop.version_esperanto.proto.DesktopVersion';

  void register(EsperantoDispatcher dispatcher) {
    dispatcher.register(
      id,
      EsperantoService(
        single: {
          'GetVersionInfo': (request) {
            proto.GetVersionRequest.fromBuffer(request);
            return identity.versionInfo().writeToBuffer();
          },
        },
      ),
    );
  }
}
