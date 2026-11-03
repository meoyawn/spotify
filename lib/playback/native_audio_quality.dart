import '../protocol/prefs_store.dart';
import 'native_audio_rank.dart';
import 'native_audio_selection.dart';

/// Concrete native backend 0x1025d83a0. Values are delivered by the real
/// core-bitrate configuration provider; missing values use its native fallbacks.
/// This is not a projection from an account's Free/Premium label.
class NativeCoreBitrateConfiguration {
  NativeCoreBitrateConfiguration({Map<String, int> integers = const {},
    Map<String, bool> booleans = const {}, this.petrelMaxRate})
    : integers = Map.unmodifiable(integers), booleans = Map.unmodifiable(booleans);
  final Map<String, int> integers;
  final Map<String, bool> booleans;
  final String? petrelMaxRate;

  NativeAudioBackendSettings backendSettings(Map<String, String> productState) {
    int? setting(String key) {
      final bitrate = (integers[key] ?? 0).toSigned(32);
      return bitrate == 0 ? null : _fromBitrate(bitrate);
    }
    return NativeAudioBackendSettings(meteredSetting: setting('default_play_bitrate_metered'),
      unmeteredSetting: setting('default_play_bitrate'),
      unmeteredSecondarySetting: booleans['hifi_target_bitrate_as_minimum_on_wifi'] == true &&
        _nativeAudioEntitlement(productState) == 2 ? 5 : 0,
      supportsCarMode: booleans['car_mode_support_enabled'] ?? false,
      downgradeOverride: booleans['car_mode_force_allow_downgrade'] ?? false);
  }

  NativeAudioFormatPolicy formatPolicy({required bool Function(int format) supportsFormat}) =>
    NativeAudioFormatPolicy(nativeFlag50: booleans['allow_24bit_flac_support'] ?? true,
      nativeFlag51: booleans['allow_xhe_aac_support'] ?? false,
      nativeFlag52: const {'Level1', 'Level2', 'Level3'}.contains(petrelMaxRate),
      supportsFormat: supportsFormat);
}

/// Inputs supplied by the original backend settings interface (+0x10, +0x18,
/// +0x38, +0x40 and +0x48). Null preserves absent native optional settings.
class NativeAudioBackendSettings {
  const NativeAudioBackendSettings({this.meteredSetting, this.unmeteredSetting,
    required this.unmeteredSecondarySetting, required this.supportsCarMode,
    required this.downgradeOverride});
  final int? meteredSetting, unmeteredSetting;
  final int unmeteredSecondarySetting;
  final bool supportsCarMode, downgradeOverride;
}

class NativeAudioQuality {
  const NativeAudioQuality({required this.setting, required this.secondarySetting,
    required this.nativeClassLimit});
  final int setting, secondarySetting, nativeClassLimit;
  NativeAudioRankPolicy get rankPolicy => NativeAudioRankPolicy(
    nativeSetting: setting, nativeClassLimit: nativeClassLimit);
}

/// Original online preference producer 0x101c15cf0 and helper 0x101c15a74.
/// Product values are actual server attributes, not a tier-name projection.
/// Preference defaults/overrides retain the existing native registry semantics.
class NativeAudioQualityPolicy {
  NativeAudioQualityPolicy({required this.preferences, required Map<String, String> productState})
    : productState = Map.unmodifiable(productState);
  final PrefsStore preferences;
  final Map<String, String> productState;

  NativeAudioQuality resolve({required NativeAudioBackendSettings backend,
    required bool isMetered, required bool useNetworkSelection,
    int? forcedUnmeteredSetting}) {
    final entitlement = _nativeAudioEntitlement(productState);
    final maximum = const [3, 4, 6][entitlement];
    final downgrade = backend.supportsCarMode && _boolean('audio.car_mode') &&
      (backend.downgradeOverride || _boolean('audio.allow_downgrade'));
    int cap(int value) {
      value = value.toSigned(32);
      return value == 0 || _settingAllows(maximum, value) ? value : maximum;
    }
    int metered() => cap(_setting('audio.play_bitrate_enumeration',
      backend.meteredSetting, null, downgrade));
    int unmetered() => cap(_setting('audio.play_bitrate_non_metered_enumeration',
      backend.unmeteredSetting, forcedUnmeteredSetting, downgrade));
    if (useNetworkSelection) {
      return NativeAudioQuality(setting: isMetered ? metered() : unmetered(),
        secondarySetting: isMetered ? 0 : backend.unmeteredSecondarySetting.toSigned(32),
        nativeClassLimit: entitlement);
    }
    final first = metered(), second = unmetered();
    return NativeAudioQuality(
      setting: first == second || !_settingAllows(first, second) ? first : second,
      secondarySetting: 0, nativeClassLimit: entitlement);
  }

  int _setting(String key, int? backendDefault, int? forced, bool downgrade) {
    final value = preferences.get(key).entries[key];
    var setting = (forced ?? value?.number.toInt() ?? 0).toSigned(32);
    if (setting < 1 || setting > 6) setting = 0;
    if (downgrade && (setting == 5 || setting == 6)) setting = 4;
    final overridden = forced != null || preferences.records().any(
      (record) => record.key == key && (record.flags & 0x160) == 0x100);
    if (setting != 0 && overridden) return setting;
    if (backendDefault != null) return backendDefault.toSigned(32);
    final bitrate = productState['default-play-bitrate'];
    if (bitrate != null) return _fromBitrate(_atoi(bitrate));
    return setting == 0 ? _fromBitrate(160000) : setting;
  }

  bool _boolean(String key) => preferences.get(key).entries[key]?.bool_2 ?? false;
}

int _nativeAudioEntitlement(Map<String, String> productState) {
  final text = productState['audio-quality'];
  final raw = text == null ? 0 : _stoi(text);
  // 0x101c14f50 explicitly falls back to Standard for foreign raw values.
  return raw >= 0 && raw < 3 ? raw : 0;
}

// Native setting descriptors contain ranks 2,4,5,6,7,8, not a tier number.
bool _settingAllows(int maximum, int value) {
  if (value == 0) return maximum.toUnsigned(32) < 7;
  const rank = {1: 2, 2: 4, 3: 5, 4: 6, 5: 7, 6: 8};
  final first = rank[maximum], second = rank[value];
  return first != null && second != null && second <= first;
}

int _fromBitrate(int value) {
  value = value.toSigned(32);
  if (value <= 0) return 0;
  if (value < 60000) return 1;
  if (value < 128000) return 2;
  if (value < 240000) return 3;
  if (value < 510000) return 4;
  return 5;
}

// Public C std::stoi(base 0) and atoi semantics. Prefix parsing is deliberate:
// native conversions accept trailing text, while absent/invalid stoi throws.
final _integerPrefix = RegExp(r'^[\x09-\x0d ]*([+-]?)(0[xX][0-9a-fA-F]+|0[0-7]*|[1-9][0-9]*)');
final _decimalPrefix = RegExp(r'^[\x09-\x0d ]*([+-]?)([0-9]+)');

int _stoi(String text) {
  final match = _integerPrefix.firstMatch(text);
  if (match == null) throw const FormatException('Invalid native product integer');
  final digits = match.group(2)!;
  final radix = digits.startsWith('0x') || digits.startsWith('0X') ? 16 : digits.startsWith('0') ? 8 : 10;
  var value = BigInt.parse(radix == 16 ? digits.substring(2) : digits, radix: radix);
  if (match.group(1) == '-') value = -value;
  if (value < BigInt.from(-0x80000000) || value > BigInt.from(0x7fffffff)) {
    throw const FormatException('Native product integer exceeds int32');
  }
  return value.toInt();
}

int _atoi(String text) {
  final match = _decimalPrefix.firstMatch(text);
  if (match == null) return 0;
  var value = BigInt.parse(match.group(2)!);
  if (match.group(1) == '-') value = -value;
  final minimum = -(BigInt.one << 63), maximum = (BigInt.one << 63) - BigInt.one;
  if (value < minimum) value = minimum;
  if (value > maximum) value = maximum;
  return value.toSigned(32).toInt();
}
