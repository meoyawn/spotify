import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'desktop_identity.dart';

typedef _SysctlNative = Int32 Function(Pointer<Utf8>, Pointer<Void>,
  Pointer<Size>, Pointer<Void>, Size);
typedef _SysctlDart = int Function(Pointer<Utf8>, Pointer<Void>,
  Pointer<Size>, Pointer<Void>, int);

typedef _TimeZoneCopyNative = Pointer<Void> Function();
typedef _TimeZoneCopyDart = Pointer<Void> Function();
typedef _TimeZoneNameNative = Pointer<Void> Function(Pointer<Void>);
typedef _TimeZoneNameDart = Pointer<Void> Function(Pointer<Void>);
typedef _CFStringCopyNative = Uint8 Function(Pointer<Void>, Pointer<Utf8>, IntPtr, Uint32);
typedef _CFStringCopyDart = int Function(Pointer<Void>, Pointer<Utf8>, int, int);
typedef _CFReleaseNative = Void Function(Pointer<Void>);
typedef _CFReleaseDart = void Function(Pointer<Void>);

/// Supplies the OS IANA zone to the renderer's explicit time-zone input.
/// Original Home uses Intl.DateTimeFormat().resolvedOptions().timeZone.
String readMacOSIanaTimeZone() {
  if (!Platform.isMacOS) throw UnsupportedError('macOS time zone is required');
  final cf = DynamicLibrary.open('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation');
  final copy = cf.lookupFunction<_TimeZoneCopyNative, _TimeZoneCopyDart>('CFTimeZoneCopyDefault');
  final name = cf.lookupFunction<_TimeZoneNameNative, _TimeZoneNameDart>('CFTimeZoneGetName');
  final stringCopy = cf.lookupFunction<_CFStringCopyNative, _CFStringCopyDart>('CFStringGetCString');
  final release = cf.lookupFunction<_CFReleaseNative, _CFReleaseDart>('CFRelease');
  final zone = copy();
  if (zone == nullptr) return '';
  final buffer = calloc<Uint8>(512).cast<Utf8>();
  try {
    final value = name(zone);
    return value != nullptr && stringCopy(value, buffer, 512, 0x08000100) != 0
      ? buffer.toDartString() : '';
  } finally { calloc.free(buffer); release(zone); }
}

/// The original hw.model wrapper is 0x100406824. This uses the same standard
/// macOS libc API in process; it does not spawn a helper or inspect an account.
class MacOSPlatformIdentity {
  const MacOSPlatformIdentity({required this.hardwareModel});
  final String hardwareModel;
  String get nativeUserAgent => DesktopIdentity.nativeUserAgent(hardwareModel);

  factory MacOSPlatformIdentity.readCurrent() {
    if (!Platform.isMacOS) throw UnsupportedError('macOS platform identity is required');
    final sysctl = DynamicLibrary.process().lookupFunction<_SysctlNative, _SysctlDart>('sysctlbyname');
    final name = 'hw.model'.toNativeUtf8();
    final length = calloc<Size>()..value = 511;
    final buffer = calloc<Uint8>(512);
    try {
      final status = sysctl(name, buffer.cast(), length, nullptr, 0);
      if (status != 0 || length.value == 0 || length.value > 512) {
        throw StateError('Could not read macOS hardware identity');
      }
      final bytes = buffer.asTypedList(length.value);
      final end = bytes.indexOf(0);
      if (end <= 0) throw StateError('Invalid macOS hardware identity');
      final model = buffer.cast<Utf8>().toDartString(length: end);
      return MacOSPlatformIdentity(hardwareModel: model);
    } finally {
      calloc.free(buffer);
      calloc.free(length);
      calloc.free(name);
    }
  }
}
