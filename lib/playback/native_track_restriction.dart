import 'dart:convert';

import '../protocol/generated/metadata.pb.dart';

enum NativeTrackCountryRule { none, allowed, forbidden }

/// Inputs read by original 0x101d04978. The deprecated catalogue enum field is
/// not consumed by that routine; catalogue_str and oneof presence are retained.
final class NativeTrackRestrictionEntry {
  const NativeTrackRestrictionEntry({required this.countryRule,
    required this.countries, required this.catalogues, this.rawType});

  factory NativeTrackRestrictionEntry.fromProtobuf(Restriction restriction) {
    final rule = switch (restriction.whichCountryRestriction()) {
      Restriction_CountryRestriction.countriesAllowed => NativeTrackCountryRule.allowed,
      Restriction_CountryRestriction.countriesForbidden => NativeTrackCountryRule.forbidden,
      Restriction_CountryRestriction.notSet => NativeTrackCountryRule.none,
    };
    return NativeTrackRestrictionEntry(countryRule: rule,
      countries: rule == NativeTrackCountryRule.allowed
        ? restriction.countriesAllowed : restriction.countriesForbidden,
      catalogues: List.unmodifiable(restriction.catalogueStr),
      rawType: restriction.hasType() ? restriction.type.value : null);
  }

  final NativeTrackCountryRule countryRule;
  final String countries;
  final List<String> catalogues;
  final int? rawType;
}

/// The restriction leaf's raw status, before TrackData readiness, source and
/// streaming guards. A zero status alone does not authorize an HTTP request.
final class NativeTrackRestrictionDecision {
  NativeTrackRestrictionDecision._(Set<String> catalogues,
    this.premiumAvailable, this.status)
    : catalogues = Set.unmodifiable(catalogues);

  final Set<String> catalogues;
  final bool premiumAvailable;
  final int status;
}

/// Original Track schema-view 0x101d07e24/0x101d08ac4 and raw admission leaf
/// 0x101d0c78c. Original execution: reverse-engineering/evidence/native-track-restrictions.json.
/// Native catalogue bits are dynamically interned names, not entitlement enums.
abstract final class NativeTrackRestrictionPolicy {
  /// The actual current clean Track path: an explicitly empty Availability
  /// list makes original 0x101d04c78 return false. Nonempty availability needs
  /// its own original date/catalogue projection and is deliberately rejected.
  static NativeTrackRestrictionDecision forTrackWithNoAvailability(Track track,
    {required String country, required String catalogue}) {
    if (track.availability.isNotEmpty) {
      throw UnsupportedError('Native Track availability projection is required');
    }
    return evaluate(
      restrictions: track.restriction.map(NativeTrackRestrictionEntry.fromProtobuf),
      country: country, catalogue: catalogue, nativeAvailabilityHasPremium: false);
  }

  /// [nativeAvailabilityHasPremium] is the explicit original 0x101d04c78 result;
  /// callers may use false only after establishing an empty Availability list.
  /// This function does not select, request, or grant permission to alternatives.
  static NativeTrackRestrictionDecision evaluate({
    required Iterable<NativeTrackRestrictionEntry> restrictions,
    required String country, required String catalogue,
    required bool nativeAvailabilityHasPremium,
  }) {
    final entries = restrictions.toList(growable: false);
    final trackCatalogues = <String>{};
    var includeAll = false;
    for (final entry in entries) {
      if (entry.rawType != null && entry.rawType != 0) continue;
      final countryBytes = utf8.encode(entry.countries);
      final hasCountries = countryBytes.isNotEmpty && countryBytes.first != 0;
      final matches = _containsCountry(countryBytes, country);
      final applies = switch (entry.countryRule) {
        NativeTrackCountryRule.none => true,
        NativeTrackCountryRule.allowed => matches,
        NativeTrackCountryRule.forbidden => !matches,
      };
      if (applies) {
        trackCatalogues.addAll(entry.catalogues.map(_cString));
      }
      // 'all' records an applicable restriction shape even when a nonempty
      // allowlist does not contain this country. It is not a grant to 'free'.
      if (entry.countryRule != NativeTrackCountryRule.allowed || hasCountries) {
        includeAll = true;
      }
    }
    if (includeAll) trackCatalogues.add('all');
    if (entries.isEmpty) trackCatalogues.add('everywhere');
    final current = _cString(catalogue);
    final accountCatalogues = current.isEmpty ? <String>{} : current.split(',').toSet();
    final premiumAvailable = trackCatalogues.contains('premium') || nativeAvailabilityHasPremium;
    final int status;
    if (trackCatalogues.any(accountCatalogues.contains) || trackCatalogues.contains('everywhere')) {
      status = 0;
    } else if (premiumAvailable) {
      status = accountCatalogues.contains('premium') ? 0 : 3;
    } else {
      status = trackCatalogues.isEmpty ? 2 : 1;
    }
    return NativeTrackRestrictionDecision._(trackCatalogues, premiumAvailable, status);
  }

  static String _cString(String value) {
    final nul = value.indexOf('\u0000');
    return nul < 0 ? value : value.substring(0, nul);
  }

  static bool _containsCountry(List<int> countries, String country) {
    final current = [...utf8.encode(country), 0, 0];
    final target = _pair(current[0], current[1]);
    for (var index = 0; index + 1 < countries.length; index += 2) {
      if (countries[index] == 0 || countries[index + 1] == 0) break;
      if (((_pair(countries[index], countries[index + 1]) ^ target) & 0xffffdfdf) == 0) {
        return true;
      }
    }
    return false;
  }

  static int _pair(int first, int second) {
    final signedFirst = first < 128 ? first : first - 256;
    final signedSecond = second < 128 ? second : second - 256;
    return ((signedFirst << 8) | signedSecond) & 0xffffffff;
  }
}
