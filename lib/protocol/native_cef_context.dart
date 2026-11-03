import 'dart:typed_data';

/// Native 0x10042c210 language inputs and 0x100044180 dedicated-context policy.
/// Inputs are explicit: construction never reads a profile or host preferences.
class NativeCefContext {
  NativeCefContext._(this.selectedLocale, this.appleLanguages, this.preferredLocales,
    this.acceptLanguageList);

  /// Startup 0x100058c08 uses the stored language when present; its dynamic
  /// default comes from 0x10042c1fc/0x10042c0e8. The caller supplies the actual
  /// resource catalogue and switch exclusions rather than assuming a locale.
  factory NativeCefContext.fromPreferences({required List<String> appleLanguages,
      required List<String> supportedLocales, List<String> excludedLocales = const [],
      String? languageOverride}) {
    for (final value in [...supportedLocales, ...excludedLocales]) { _ascii(value); }
    final preferred = appleLanguages.isEmpty ? const ['en'] : appleLanguages;
    var selected = 'en';
    var found = false;
    for (final preference in preferred) {
      for (final candidate in expandPreferredLocale(preference)) {
        if (supportedLocales.contains(candidate) && !excludedLocales.contains(candidate)) {
          selected = candidate;
          found = true;
          break;
        }
      }
      if (found) break;
    }
    return NativeCefContext.fromLocale(selectedLocale: languageOverride ?? selected,
      appleLanguages: appleLanguages);
  }

  factory NativeCefContext.fromLocale({required String selectedLocale,
      required List<String> appleLanguages}) {
    _ascii(selectedLocale);
    for (final value in appleLanguages) { _ascii(value); }
    final preferred = appleLanguages.isEmpty ? <String>['en'] : List<String>.of(appleLanguages);
    final matching = <String>[];
    for (final value in preferred) {
      for (final expanded in expandPreferredLocale(value)) {
        if (expanded == selectedLocale) matching.add(value);
      }
    }
    if (matching.isEmpty) {
      matching.add(selectedLocale);
    } else if (!matching.contains(selectedLocale)) {
      matching.add(selectedLocale);
    }
    return NativeCefContext._(selectedLocale, List.unmodifiable(appleLanguages),
      List.unmodifiable(preferred), matching.join(','));
  }

  final String selectedLocale, acceptLanguageList;
  final List<String> appleLanguages, preferredLocales;

  /// Public macOS arm64 cef_request_context_settings_t API999999, captured
  /// before original CreateContext. All fields are zero except size/exclusion.
  Uint8List get requestContextSettings {
    final bytes = Uint8List(96), data = ByteData(96);
    data.setUint64(0, 96, Endian.little);
    data.setUint32(88, 1, Endian.little);
    bytes.setAll(0, data.buffer.asUint8List());
    return bytes;
  }

  /// Chromium151 HttpUtil::ExpandLanguageList + GenerateAcceptLanguageHeader.
  String get acceptLanguageHeader {
    if (acceptLanguageList.isEmpty) {
      throw UnsupportedError('Empty native language lists require an explicit global-default profile');
    }
    final languages = acceptLanguageList.split(',').map((value) => value.trim()).toList();
    final expanded = <String>[], seen = <String>{};
    void add(String value) { if (seen.add(value)) expanded.add(value); }
    String base(String value) => value.split('-').first.trim();
    for (var index = 0; index < languages.length; index++) {
      final value = languages[index];
      if (value.contains(RegExp(r'[;\x00-\x20\x7f]'))) {
        throw UnsupportedError('CEF language header inputs must be ASCII codes without quality scores');
      }
      add(value);
      final primary = base(value);
      if (primary != 'x' && primary != 'i' &&
          (index + 1 == languages.length || base(languages[index + 1]) != primary)) {
        add(primary);
      }
    }
    return [for (var index = 0; index < expanded.length; index++)
      index == 0 ? expanded[index] : '${expanded[index]};q=0.${10 - index < 1 ? 1 : 10 - index}'].join(',');
  }

  /// Proprietary 0x100423abc/0x1004238b4, with the caller's empty script list.
  /// Case, original preference spelling, duplicate matches and alias order matter.
  static List<String> expandPreferredLocale(String value) {
    _ascii(value);
    final parts = value.split(RegExp('[-_]'));
    final language = parts.first, scripts = <String>[];
    var region = '';
    if (parts.length == 2) {
      if (parts[1].length == 2 || parts[1].length == 3) {
        region = parts[1];
      } else if (parts[1].length == 4) {
        scripts.add(parts[1]);
      }
    } else if (parts.length == 3 && parts[1].length == 4 &&
        (parts[2].length == 2 || parts[2].length == 3)) {
      scripts.add(parts[1]);
      region = parts[2];
    }
    if (language == 'zh') {
      final inferred = const {'HK': 'Hant', 'MO': 'Hant', 'TW': 'Hant',
        'CN': 'Hans', 'MY': 'Hans', 'SG': 'Hans'}[region];
      if (inferred != null && !scripts.contains(inferred)) scripts.add(inferred);
    }
    final result = <String>[];
    void appendRegion(String region, Iterable<String> scripts) {
      if (region.isEmpty) return;
      for (final script in scripts) {
        if (script.isNotEmpty) result.add('$language-$script-$region');
      }
      result.add('$language-$region');
    }
    appendRegion(region, scripts);
    if (const {'AR', 'BO', 'CL', 'CO', 'CR', 'DO', 'EC', 'SV', 'GT', 'HN',
        'MX', 'NI', 'PA', 'PY', 'PE', 'PR', 'UY', 'VE', '419', 'LA'}.contains(region)) {
      if (region != '419') appendRegion('419', scripts);
      if (region != 'LA') appendRegion('LA', const []);
    }
    for (final script in scripts) {
      if (script.isNotEmpty) result.add('$language-$script');
    }
    result.add(language);
    return List.unmodifiable(result);
  }
}

void _ascii(String value) {
  if (value.codeUnits.any((code) => code == 0 || code > 127)) {
    throw UnsupportedError('Native CEF locale projection supports NUL-free ASCII locale inputs');
  }
}
