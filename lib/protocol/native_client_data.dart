import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:fixnum/fixnum.dart' show Int64;

import 'desktop_identity.dart';
import 'generated/connectivity.pb.dart' as data;
import 'generated/spotify/client_token/v0/client_token_http.pb.dart' as token;
import 'platform_identity.dart';

final class _OperatingSystemVersion extends Struct {
  @IntPtr()
  external int major;
  @IntPtr()
  external int minor;
  @IntPtr()
  external int patch;
}

typedef _ObjectNative = Pointer<Void> Function(Pointer<Void>, Pointer<Void>);
typedef _ObjectDart = Pointer<Void> Function(Pointer<Void>, Pointer<Void>);
typedef _VersionNative = _OperatingSystemVersion Function(Pointer<Void>, Pointer<Void>);
typedef _VersionDart = _OperatingSystemVersion Function(Pointer<Void>, Pointer<Void>);
typedef _LookupNative = Pointer<Void> Function(Pointer<Utf8>);
typedef _LookupDart = Pointer<Void> Function(Pointer<Utf8>);
typedef _PoolPushNative = Pointer<Void> Function();
typedef _PoolPushDart = Pointer<Void> Function();
typedef _PoolPopNative = Void Function(Pointer<Void>);
typedef _PoolPopDart = void Function(Pointer<Void>);
typedef _HostNative = Uint32 Function();
typedef _HostDart = int Function();
typedef _HostInfoNative = Int32 Function(Uint32, Int32, Pointer<Int32>, Pointer<Uint32>);
typedef _HostInfoDart = int Function(int, int, Pointer<Int32>, Pointer<Uint32>);
typedef _PortReleaseNative = Int32 Function(Uint32, Uint32);
typedef _PortReleaseDart = int Function(int, int);

/// Public system facts used by the native MacOS client-data factory.
/// Device and installation identifiers are separate, explicitly supplied inputs.
class MacOSPlatformFacts {
  const MacOSPlatformFacts({required this.systemVersionString,
    required this.majorVersion, required this.minorVersion, required this.patchVersion,
    required this.hardwareModel, required this.cpuType, required this.cpuSubtype});

  final String systemVersionString, hardwareModel;
  final int majorVersion, minorVersion, patchVersion, cpuType, cpuSubtype;
  String get numericVersion => '$majorVersion.$minorVersion.$patchVersion';

  /// Reuses Foundation NSProcessInfo, libc sysctl and Mach host_info in process.
  factory MacOSPlatformFacts.readCurrent() {
    if (!Platform.isMacOS || Abi.current() != Abi.macosArm64) {
      throw UnsupportedError('The reconstructed MacOS client-data factory requires arm64 macOS');
    }
    DynamicLibrary.open('/System/Library/Frameworks/Foundation.framework/Foundation');
    final objc = DynamicLibrary.open('/usr/lib/libobjc.A.dylib');
    final getClass = objc.lookupFunction<_LookupNative, _LookupDart>('objc_getClass');
    final selector = objc.lookupFunction<_LookupNative, _LookupDart>('sel_registerName');
    final send = objc.lookupFunction<_ObjectNative, _ObjectDart>('objc_msgSend');
    final version = objc.lookupFunction<_VersionNative, _VersionDart>('objc_msgSend');
    final pushPool = objc.lookupFunction<_PoolPushNative, _PoolPushDart>('objc_autoreleasePoolPush');
    final popPool = objc.lookupFunction<_PoolPopNative, _PoolPopDart>('objc_autoreleasePoolPop');
    Pointer<Void> lookup(String name, _LookupDart operation) {
      final text = name.toNativeUtf8();
      try { return operation(text); } finally { calloc.free(text); }
    }
    Pointer<Void> message(Pointer<Void> object, String name) => send(object, lookup(name, selector));
    final pool = pushPool();
    try {
      final process = message(lookup('NSProcessInfo', getClass), 'processInfo');
      if (process == nullptr) throw StateError('NSProcessInfo is unavailable');
      final description = message(process, 'operatingSystemVersionString');
      final utf8 = message(description, 'UTF8String').cast<Utf8>();
      if (utf8 == nullptr) throw StateError('macOS version string is unavailable');
      final systemVersion = utf8.toDartString();
      final osVersion = version(process, lookup('operatingSystemVersion', selector));
      final libc = DynamicLibrary.process();
      final hostSelf = libc.lookupFunction<_HostNative, _HostDart>('mach_host_self');
      final hostInfo = libc.lookupFunction<_HostInfoNative, _HostInfoDart>('host_info');
      final releasePort = libc.lookupFunction<_PortReleaseNative, _PortReleaseDart>('mach_port_deallocate');
      final task = libc.lookup<Uint32>('mach_task_self_').value;
      final basic = calloc<Int32>(12);
      final count = calloc<Uint32>()..value = 12;
      final host = hostSelf();
      try {
        final status = hostInfo(host, 1, basic, count);
        if (status != 0 || count.value < 5) throw StateError('Could not read HOST_BASIC_INFO ($status)');
        return MacOSPlatformFacts(systemVersionString: systemVersion,
          majorVersion: osVersion.major, minorVersion: osVersion.minor, patchVersion: osVersion.patch,
          hardwareModel: MacOSPlatformIdentity.readCurrent().hardwareModel,
          cpuType: basic[3], cpuSubtype: basic[4]);
      } finally {
        if (host != 0) releasePort(task, host);
        calloc.free(count);
        calloc.free(basic);
      }
    } finally {
      popPool(pool);
    }
  }

  data.NativeDesktopMacOSData toClientData() => data.NativeDesktopMacOSData(
    systemVersion: _nonempty(systemVersionString),
    systemVersionMajor: majorVersion == 0 ? null : Int64(majorVersion),
    systemVersionMinor: minorVersion == 0 ? null : Int64(minorVersion),
    systemVersionPatch: patchVersion == 0 ? null : Int64(patchVersion),
    hwModel: _nonempty(hardwareModel), cpuType: cpuType == 0 ? null : cpuType,
    cpuSubtype: cpuSubtype == 0 ? null : cpuSubtype, compiledCpuType: 'arm64',
  );
}

/// Proprietary selection and field mapping at 0x1017c0608/0x1017c35a4.
/// Identity strings come from the owning configuration, never from this factory.
class NativeClientDataFactory {
  const NativeClientDataFactory({required this.facts, required this.clientId,
    required this.deviceId, this.clientVersion = DesktopIdentity.fullVersion,
    this.developerApiKey});

  final MacOSPlatformFacts facts;
  final String clientId, clientVersion, deviceId;
  final String? developerApiKey;

  token.ClientDataRequest create({String? currentToken}) {
    final sdk = data.ConnectivitySdkData(
      deviceId: _nonempty(deviceId),
      platformSpecificData: data.PlatformSpecificData(mac: facts.toClientData()),
    );
    if (developerApiKey?.isNotEmpty == true) sdk.developerApiKey = developerApiKey!;
    return token.ClientDataRequest(clientVersion: _nonempty(clientVersion), clientId: _nonempty(clientId),
      connectivitySdkData: sdk, currentToken: _nonempty(currentToken));
  }
}

String? _nonempty(String? value) => value == null || value.isEmpty ? null : value;
