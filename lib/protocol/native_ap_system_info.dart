import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../playback/generated/authentication.pb.dart' as auth;

typedef _GestaltNative = Int16 Function(Uint32, Pointer<Int32>);
typedef _GestaltDart = int Function(int, Pointer<Int32>);
typedef _HostNative = Uint32 Function();
typedef _HostDart = int Function();
typedef _HostInfoNative = Int32 Function(Uint32, Int32, Pointer<Int32>, Pointer<Uint32>);
typedef _HostInfoDart = int Function(int, int, Pointer<Int32>, Pointer<Uint32>);
typedef _ReleaseNative = Int32 Function(Uint32, Uint32);
typedef _ReleaseDart = int Function(int, int);

/// One public OS snapshot used by native 0x101a4c860/0x101a4c9ec. Gestalt
/// versions are distinct from Foundation's operatingSystemVersion values.
class NativeApSystemFacts {
  const NativeApSystemFacts({required this.majorVersion, required this.minorVersion,
    required this.patchVersion, required this.cpuType, required this.cpuSubtype,
    this.gestaltSucceeded = true});
  final int majorVersion, minorVersion, patchVersion, cpuType, cpuSubtype;
  final bool gestaltSucceeded;

  /// Calls the same standard APIs as the original wrappers, in their order.
  /// Any Gestalt failure short-circuits the remaining selectors and resets all
  /// three version fields. HOST_BASIC_INFO is still read after that failure.
  factory NativeApSystemFacts.readCurrent() {
    if (!Platform.isMacOS) throw UnsupportedError('Native AP system facts require macOS');
    final services = DynamicLibrary.open('/System/Library/Frameworks/CoreServices.framework/CoreServices');
    final gestalt = services.lookupFunction<_GestaltNative, _GestaltDart>('Gestalt');
    final libc = DynamicLibrary.process();
    final hostSelf = libc.lookupFunction<_HostNative, _HostDart>('mach_host_self');
    final hostInfo = libc.lookupFunction<_HostInfoNative, _HostInfoDart>('host_info');
    final release = libc.lookupFunction<_ReleaseNative, _ReleaseDart>('mach_port_deallocate');
    final task = libc.lookup<Uint32>('mach_task_self_').value;
    final version = calloc<Int32>(3), basic = calloc<Int32>(12);
    final count = calloc<Uint32>()..value = 12;
    var host = 0, succeeded = true;
    try {
      for (var i = 0; i < 3; i++) {
        if (gestalt(0x73797331 + i, version + i) != 0) {
          succeeded = false;
          for (var j = 0; j < 3; j++) { version[j] = 0; }
          break;
        }
      }
      host = hostSelf();
      final status = hostInfo(host, 1, basic, count);
      // The original ignores a failed host_info and would read unspecified
      // stack bytes. No deterministic identity is claimed for that failure.
      if (status != 0 || count.value < 5) throw StateError('HOST_BASIC_INFO failed ($status)');
      return NativeApSystemFacts(majorVersion: version[0], minorVersion: version[1],
        patchVersion: version[2], cpuType: basic[3], cpuSubtype: basic[4],
        gestaltSucceeded: succeeded);
    } finally {
      if (host != 0) release(task, host);
      calloc.free(version);
      calloc.free(basic);
      calloc.free(count);
    }
  }
}

/// Original AP SystemInfo projection: packed scalar helper 0x101a4c860,
/// description helper 0x101a4c9ec and all-eight-scalar assignment/presence in
/// 0x101902fa8. The original instructions/serializer are independently exercised
/// in reverse-engineering/fixtures/native-ap-system-info.json with synthetic platform facts.
class NativeApSystemInfo {
  const NativeApSystemInfo._({required this.cpuFamily, required this.cpuSubtype,
    required this.osVersion, required this.osExt, required this.systemInformationString});

  final int cpuFamily, cpuSubtype, osVersion, osExt;
  final String systemInformationString;
  int get cpuExt => 0;
  int get brand => 0;
  int get brandFlags => 0;
  int get os => 2;

  /// The original AP builder invokes both helpers separately. Supplying a
  /// separate description snapshot preserves that distinction without guessing
  /// that the later standard OS query must return the earlier values.
  factory NativeApSystemInfo.fromFacts(NativeApSystemFacts facts,
    {NativeApSystemFacts? descriptionFacts}) {
    final version = _version(facts);
    final type = facts.cpuType.toSigned(32);
    final family = switch (type) {
      7 => 1, 0x1000007 => 2, 18 => 3, 0x1000012 => 4,
      12 || 0x100000c || 0x200000c => 5, _ => 0,
    };
    final description = descriptionFacts ?? facts;
    final displayVersion = _version(description);
    final label = switch (description.cpuType.toSigned(32)) {
      7 => 'x86', 0x1000007 => 'x86-64', 18 => 'ppc', 0x1000012 => 'ppc-64',
      12 || 0x100000c || 0x200000c => 'arm', _ => 'unknown',
    };
    return NativeApSystemInfo._(cpuFamily: family, cpuSubtype: facts.cpuSubtype & 255,
      osVersion: (version.$1 * 10 + version.$2) & 255, osExt: version.$3 & 255,
      systemInformationString: 'OS X ${displayVersion.$1}.${displayVersion.$2}.${displayVersion.$3} [$label ${description.cpuSubtype.toSigned(32)}]');
  }

  factory NativeApSystemInfo.readCurrent() {
    final scalars = NativeApSystemFacts.readCurrent();
    final description = NativeApSystemFacts.readCurrent();
    return NativeApSystemInfo.fromFacts(scalars, descriptionFacts: description);
  }

  /// The public reference schema's field numbers and observed scalar values
  /// match original ctor 0x101910ea8/writer 0x101911674. Its enum declarations
  /// are reference-derived; no broader original enum reconstruction is claimed.
  /// All eight proto2 scalars, the description, and the explicit device string
  /// are set even when zero/empty. Device identity belongs to the caller.
  auth.SystemInfo toMessage({required String deviceId}) => auth.SystemInfo(
    cpuFamily: auth.CpuFamily.valueOf(cpuFamily)!, cpuSubtype: cpuSubtype,
    cpuExt: cpuExt, brand: auth.Brand.valueOf(brand)!, brandFlags: brandFlags,
    os: auth.Os.valueOf(os)!, osVersion: osVersion, osExt: osExt,
    systemInformationString: systemInformationString, deviceId: deviceId);
}

(int, int, int) _version(NativeApSystemFacts facts) => facts.gestaltSucceeded
  ? (facts.majorVersion.toSigned(32), facts.minorVersion.toSigned(32), facts.patchVersion.toSigned(32))
  : (0, 0, 0);
