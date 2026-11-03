import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:fixnum/fixnum.dart' show Int64;

import 'desktop_identity.dart';
import 'esperanto.dart';
import 'generated/es_desktop_platform_info.pb.dart' as proto;
import 'native_client_data.dart';

typedef _GestaltNative = Int16 Function(Uint32, Pointer<Int32>);
typedef _GestaltDart = int Function(int, Pointer<Int32>);

/// Legacy Gestalt values used only for the desktop display description.
/// Foundation's separate version values remain in [MacOSPlatformFacts].
class MacOSGestaltVersion {
  const MacOSGestaltVersion(this.major, this.minor, this.patch);
  final int major, minor, patch;

  factory MacOSGestaltVersion.readCurrent() {
    if (!Platform.isMacOS) throw UnsupportedError('Gestalt requires macOS');
    final library = DynamicLibrary.open('/System/Library/Frameworks/CoreServices.framework/CoreServices');
    final gestalt = library.lookupFunction<_GestaltNative, _GestaltDart>('Gestalt');
    final version = calloc<Int32>(3);
    try {
      for (var i = 0; i < 3; i++) {
        if (gestalt(0x73797331 + i, version + i) != 0) return const MacOSGestaltVersion(0, 0, 0);
      }
      return MacOSGestaltVersion(version[0], version[1], version[2]);
    } finally {
      calloc.free(version);
    }
  }

  String description(MacOSPlatformFacts facts) {
    final architecture = switch (facts.cpuType) {
      7 => 'x86', 0x1000007 => 'x86-64',
      12 || 0x100000c || 0x200000c => 'arm',
      18 => 'ppc', 0x1000012 => 'ppc-64', _ => 'unknown',
    };
    return 'OS X ${major.toSigned(32)}.${minor.toSigned(32)}.${patch.toSigned(32)} [$architecture ${facts.cpuSubtype.toSigned(32)}]';
  }
}

/// Values read anew from the owning desktop configuration for each request.
class DesktopPlatformSettings {
  const DesktopPlatformSettings({required this.locale,
    required this.isDeveloperMode});
  final String locale;
  final bool isDeveloperMode;
}

/// Native constructor context; these strings have independent identity sources.
class DesktopEventContext {
  const DesktopEventContext({required this.platformType, required this.clientId,
    required this.installationId, this.deviceId, this.deviceManufacturer,
    this.deviceModel, this.osVersion,
    this.clientVersionString = DesktopIdentity.fullVersion,
    this.clientVersionInt = DesktopIdentity.numericVersion});
  final String platformType, clientId, installationId, clientVersionString;
  final String? deviceId, deviceManufacturer, deviceModel, osVersion;
  final int clientVersionInt;

  proto.EventSenderContextInformation toMessage() {
    final version = clientVersionInt.toUnsigned(32);
    return proto.EventSenderContextInformation(
      deviceId: _nonempty(deviceId), deviceManufacturer: _nonempty(deviceManufacturer),
      deviceModel: _nonempty(deviceModel), osVersion: _nonempty(osVersion),
      platformType: _nonempty(platformType), clientId: _nonempty(clientId),
      clientVersionString: _nonempty(clientVersionString),
      clientVersionInt: version == 0 ? null : Int64(version), installationId: _nonempty(installationId),
    );
  }
}

/// Pure Dart local service for native provider 0x10007aba8/handler 0x1000f352c.
class DesktopPlatformService {
  const DesktopPlatformService({required this.facts, required this.gestaltVersion,
    required this.eventContext, required this.settings, required this.loadConnectModal});
  static const id = 'spotify.desktop.platform_info_esperanto.proto.DesktopPlatformInfo';
  final MacOSPlatformFacts facts;
  final MacOSGestaltVersion gestaltVersion;
  final DesktopEventContext eventContext;
  final DesktopPlatformSettings Function() settings;
  final bool loadConnectModal;

  static const _rtlLocales = {'ar', 'dv', 'fa', 'ha', 'he', 'ks', 'ku', 'ps', 'ur', 'yi',
    'arc', 'khw', 'ar-EG', 'ar-MA', 'ar-SA'};

  proto.PlatformInfoResponse platformInfo() {
    final config = settings();
    return proto.PlatformInfoResponse(
      locale: _nonempty(config.locale),
      localizationIsRtl: _rtlLocales.contains(config.locale) ? true : null,
      loadConnectModal: loadConnectModal ? true : null,
      appPlatform: DesktopIdentity.appPlatform, osVersion: facts.numericVersion,
      eventSenderContextInformation: eventContext.toMessage(),
      isDeveloperMode: config.isDeveloperMode ? true : null,
      capabilities: proto.Capabilities(canAutostart: true, canRestart: true),
      clientVersion: DesktopIdentity.fullVersion, platformString: gestaltVersion.description(facts),
    );
  }

  void register(EsperantoDispatcher dispatcher) {
    dispatcher.register(id, EsperantoService(single: {'GetPlatformInfo': (request) {
      proto.GetPlatformInfoRequest.fromBuffer(request);
      return platformInfo().writeToBuffer();
    }}));
  }
}

String? _nonempty(String? value) => value == null || value.isEmpty ? null : value;
