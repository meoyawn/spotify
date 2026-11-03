import '../protocol/generated/es_context_player_error.pb.dart' as wire;
import '../protocol/generated/es_context_player_state.pb.dart' as wire;
import '../protocol/generated/es_provided_track.pb.dart' as wire;
import '../protocol/generated/es_restrictions.pb.dart' as wire;
import 'requests.dart';
import '../content/advertising.dart';

typedef PlaybackJson = Map<String, Object?>;

Object? _freeze(Object? value) {
  if (value is Map<String, Object?>) {
    return Map<String, Object?>.unmodifiable(value.map((key, item) => MapEntry(key, _freeze(item))));
  }
  if (value is List) return List<Object?>.unmodifiable(value.map(_freeze));
  return value;
}

/// Immutable renderer projection of a native ProvidedTrack.
class PlaybackItem {
  PlaybackItem._(PlaybackJson fields) : _fields = _freeze(fields) as PlaybackJson;
  final PlaybackJson _fields;
  String get type => _fields['type'] as String;
  String get uri => _fields['uri'] as String;
  String get uid => _fields['uid'] as String;
  String get name => (_fields['name'] ?? _fields['title'] ?? '') as String;
  String get mediaType => _fields['mediaType'] as String;
  int? get durationMs => (_fields['duration'] as PlaybackJson)['milliseconds'] as int?;
  String? get provider => _fields['provider'] as String?;
  Map<String, String> get metadata => (_fields['metadata'] as Map).cast<String, String>();
  List<PlaybackJson> get images => (_fields['images'] as List).cast<PlaybackJson>();
  bool get isAdvertising => isAdvertisement(uri, metadata);
  PlaybackJson toJson() => _fields;
}

class PlaybackRestrictions {
  PlaybackRestrictions._(PlaybackJson fields) : _fields = _freeze(fields) as PlaybackJson;
  final PlaybackJson _fields;
  bool get canPause => _fields['canPause'] as bool;
  bool get canResume => _fields['canResume'] as bool;
  bool get canSeek => _fields['canSeek'] as bool;
  bool get canSkipPrevious => _fields['canSkipPrevious'] as bool;
  bool get canSkipNext => _fields['canSkipNext'] as bool;
  bool get canToggleShuffle => _fields['canToggleShuffle'] as bool;
  bool get canToggleSmartShuffle => _fields['canToggleSmartShuffle'] as bool;
  bool get canToggleRepeatContext => _fields['canToggleRepeatContext'] as bool;
  bool get canToggleRepeatTrack => _fields['canToggleRepeatTrack'] as bool;
  List<String> reasons(String key) => (_fields[key] as List? ?? []).cast<String>();
  PlaybackJson toJson() => _fields;
}

class PlaybackState {
  PlaybackState._(PlaybackJson fields) : _fields = _freeze(fields) as PlaybackJson;
  final PlaybackJson _fields;
  int get timestamp => _fields['timestamp'] as int;
  int get positionAsOfTimestamp => _fields['positionAsOfTimestamp'] as int;
  int? get durationMs => _fields['duration'] as int?;
  bool get hasContext => _fields['hasContext'] as bool;
  bool get isPaused => _fields['isPaused'] as bool;
  bool get isBuffering => _fields['isBuffering'] as bool;
  bool? get shuffle => _fields['shuffle'] as bool?;
  bool? get smartShuffle => _fields['smartShuffle'] as bool?;
  PlaybackRepeat? get repeat => _fields['repeat'] == null ? null : PlaybackRepeat.values[_fields['repeat'] as int];
  double get speed => (_fields['speed'] as num).toDouble();
  String? get playbackId => _fields['playbackId'] as String?;
  String get sessionId => _fields['sessionId'] as String;
  PlaybackJson get context => _fields['context'] as PlaybackJson;
  PlaybackJson get index => _fields['index'] as PlaybackJson;
  PlaybackItem? get item {
    final value = _fields['item'] == null ? null : PlaybackItem._(_fields['item'] as PlaybackJson);
    return value?.isAdvertising == true ? null : value;
  }
  bool get isAdvertising => _fields['item'] != null && PlaybackItem._(_fields['item'] as PlaybackJson).isAdvertising;
  List<PlaybackItem> get previousItems => (_fields['previousItems'] as List).map((item) => PlaybackItem._(item as PlaybackJson))
    .where((item) => !item.isAdvertising).toList(growable: false);
  List<PlaybackItem> get nextItems => (_fields['nextItems'] as List).map((item) => PlaybackItem._(item as PlaybackJson))
    .where((item) => !item.isAdvertising).toList(growable: false);
  PlaybackRestrictions get restrictions => PlaybackRestrictions._(_fields['restrictions'] as PlaybackJson);
  List<String> get signals => (_fields['signals'] as List).cast<String>();
  PlaybackJson toJson() => _fields;

  factory PlaybackState.fromMessage(wire.ContextPlayerState state) {
    final options = state.options;
    final speed = state.hasPlaybackSpeed()
      ? state.playbackSpeed.value : null;
    final formatUnknown = state.unknownFields.hasField(29);
    final fields = <String, Object?>{
      'timestamp': state.timestamp.toInt(),
      'context': {'uri': state.contextUri, 'url': state.contextUrl, 'metadata': state.contextMetadata},
      'index': {'pageURI': state.pageMetadata['page_uri'],
        'pageIndex': state.hasIndex() ? state.index.page.toInt() : null,
        'itemIndex': state.hasIndex() ? state.index.track.toInt() : null},
      'item': state.hasTrack() && state.track.hasContextTrack() ? _projectItem(state.track) : null,
      'shuffle': state.hasOptions() ? options.shufflingContext : null,
      'smartShuffle': state.hasOptions() ? options.shufflingContext &&
        (options.modes['context_enhancement'] == 'RECOMMENDATION' || state.contextMetadata['enhanced_context'] == 'true') : null,
      'repeat': state.hasOptions() ? (options.repeatingTrack ? 2 : options.repeatingContext ? 1 : 0) : null,
      'speed': speed == null ? 1 : speed == 0 || speed.isNaN ? (options.hasPlaybackSpeed() ? options.playbackSpeed : 1) : speed,
      'speedEsperanto': options.hasPlaybackSpeed() ? options.playbackSpeed : 1,
      'positionAsOfTimestamp': state.positionAsOfTimestamp.value.toInt(),
      'duration': state.hasDuration() ? state.duration.value.toInt() : null,
      'hasContext': state.isPlaying && state.hasTrack(),
      'isPaused': state.isPaused, 'isBuffering': state.isBuffering,
      'restrictions': _projectRestrictions(state.hasRestrictions() ? state.restrictions : null),
      'previousItems': state.prevTracks.where((item) => item.hasContextTrack()).map(_projectItem).toList(),
      'nextItems': state.nextTracks.where((item) => item.hasContextTrack()).map(_projectItem).toList(),
      'playbackQuality': {'bitrateLevel': _quality(state.playbackQuality.bitrateLevel.value),
        'strategy': state.playbackQuality.strategy.value,
        'targetBitrateLevel': _quality(state.playbackQuality.targetBitrateLevel.value),
        'targetBitrateAvailable': state.playbackQuality.targetBitrateAvailable,
        'losslessStatus': state.playbackQuality.hifiStatus.value},
      'playbackId': state.playbackId.isEmpty ? null : state.playbackId.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join(),
      'sessionId': state.sessionId, 'signals': state.signals,
      'format': formatUnknown ? 3 : state.hasFormat() ? state.format.value : null,
    };
    if (state.signals.contains('switch-to-video')) {
      fields['mediaPlaybackMode'] = 'audio';
    } else if (state.signals.contains('switch-to-audio')) {
      fields['mediaPlaybackMode'] = 'video';
    }
    if (state.hasAdBreakContext()) {
      fields['adBreakContext'] = {'maxSecondsRemaining': state.adBreakContext.maxSecondsRemaining.toInt(),
        'positionInCurrentAdBreak': state.adBreakContext.positionInCurrentAdBreak.toInt(),
        'totalAdsInBreakEstimate': state.adBreakContext.totalAdsInBreakEstimate.toInt()};
    }
    if (state.hasSleepTimer()) {
      fields['sleepTimer'] = {'type': state.sleepTimer.hasTimestamp() ? 1 : state.sleepTimer.hasEndOfTrack() ? 2 : 0,
        'timestamp': state.sleepTimer.hasTimestamp() ? state.sleepTimer.timestamp.timestamp.toInt() : null};
    }
    return PlaybackState._(fields);
  }

  PlaybackState withItemMetadata(Map<String, String> metadata) {
    final projected = _fields['item'] as PlaybackJson?;
    return projected == null ? this : PlaybackState._({..._fields,
      'item': {...projected, 'metadata': metadata}});
  }
}

int _quality(int value) => value >= 0 && value <= 6 ? value : 0;

List<PlaybackJson> _images(Map<String, String> metadata) => [
  for (final entry in const {'image_url': 'standard', 'image_small_url': 'small',
      'image_large_url': 'large', 'image_xlarge_url': 'xlarge'}.entries)
    if (metadata[entry.key]?.isNotEmpty == true) {'url': metadata[entry.key], 'label': entry.value},
];

List<PlaybackJson> _artists(Map<String, String> metadata) {
  final items = <PlaybackJson>[{'type': 'artist', 'uri': metadata['artist_uri'] ?? '', 'name': metadata['artist_name'] ?? ''}];
  for (var i = 1; i <= 9; i++) {
    if (metadata['artist_uri:$i']?.isNotEmpty != true || metadata['artist_name:$i']?.isNotEmpty != true) break;
    items.add({'type': 'artist', 'uri': metadata['artist_uri:$i'], 'name': metadata['artist_name:$i']});
  }
  return items;
}

bool _truth(String? value) => value?.toLowerCase() == 'true';
int? _duration(String? value) {
  if (value == null || value.isEmpty) return -1;
  final prefix = RegExp(r'^\s*([+-]?\d+)').firstMatch(value)?.group(1);
  return prefix == null ? null : int.tryParse(prefix);
}

PlaybackJson _projectItem(wire.ProvidedTrack item) {
  final track = item.contextTrack;
  final metadata = track.metadata;
  final uriType = playbackUriType(track.uri);
  final type = switch (uriType) {
    'track' || 'local' => 'track', 'kallax' => 'kallax',
    'podcast-chapter' || 'clip' => 'podcast-chapter',
    'episode' => metadata['is_audiobook_chapter'] == 'true' ? 'chapter' : 'episode',
    'ad' => 'ad', _ => 'unknown',
  };
  final images = _images(metadata);
  final fields = <String, Object?>{'type': type, 'uri': track.uri, 'uid': track.uid,
    'mediaType': metadata['media.type'] ?? 'audio', 'duration': {'milliseconds': _duration(metadata['duration'])},
    'provider': item.provider.isEmpty ? null : item.provider, 'metadata': metadata, 'images': images};
  if (type == 'ad') {
    fields.addAll({'title': metadata['title'], 'advertiser': metadata['advertiser'],
      'url': metadata['click_url'], 'id': metadata['ad_id'],
      if (metadata.containsKey('ad.video_orientation')) 'videoOrientation': metadata['ad.video_orientation'],
      'isPodcastAd': _truth(metadata['is_podcast_advertisement']),
      'isSkippableAd': _truth(metadata['ad.is_skippable']), 'isTestAd': _truth(metadata['ad.is_test'])});
    return fields;
  }
  fields['name'] = metadata['title'] ?? '';
  if (type != 'unknown') {
    fields['isExplicit'] = _truth(metadata['is_explicit']);
    fields['is19PlusOnly'] = _truth(metadata['is_19_plus']);
  }
  if (type == 'track' || type == 'kallax' || type == 'unknown') {
    fields['album'] = {'type': 'album', 'uri': metadata['album_uri'] ?? '',
      'name': metadata['album_title'] ?? '', 'images': images};
    fields['artists'] = _artists(metadata);
    if (type != 'unknown') fields['hasAssociatedVideo'] = metadata['video_association']?.isNotEmpty == true;
    if (type == 'track') fields['isLocal'] = _truth(metadata['is_local']);
  } else if (type == 'podcast-chapter') {
    fields['episode'] = {'type': 'episode', 'uri': metadata['album_uri'] ?? '', 'name': metadata['album_title'] ?? '', 'images': images};
    fields['show'] = {'type': 'show', 'uri': metadata['artist_uri'] ?? '', 'name': metadata['artist_name'] ?? '', 'images': <Object?>[]};
  } else if (type == 'chapter') {
    final authors = <int, PlaybackJson>{};
    for (final entry in metadata.entries.where((entry) => entry.key.startsWith('author_'))) {
      final parts = entry.key.split(':');
      final index = parts.length > 1 ? int.tryParse(parts[1]) : 0;
      if (index == null || index < 0) continue;
      final author = authors.putIfAbsent(index, () => {'uri': null, 'name': ''});
      if (parts[0] == 'author_name') author['name'] = entry.value;
      if (parts[0] == 'author_uri') author['uri'] = entry.value;
    }
    fields['artists'] = <Object?>[];
    fields['book'] = {'type': 'audiobook', 'uri': metadata['album_uri'] ?? '', 'name': metadata['album_title'] ?? '',
      'images': images, 'authors': (authors.keys.toList()..sort()).map((key) => authors[key]!).where((author) => (author['name'] as String).isNotEmpty).toList()};
  } else {
    fields['artists'] = <Object?>[];
    fields['show'] = {'type': 'show', 'uri': metadata['album_uri'] ?? '', 'name': metadata['album_title'] ?? '', 'images': images};
  }
  return fields;
}

const _reasons = {'not_playing_locally', 'not_playing_context', 'not_playing_track', 'no_prev_track', 'no_next_track',
  'no_specific_track', 'already_paused', 'not_paused', 'context_player_disallow', 'mft_disallow', 'ad_disallow',
  'protocol_limitations', 'unknown', 'already_playing', 'throttled', 'endless_context', 'autoplay', 'narration',
  'not_supported_by_device', 'no_associated_track', 'age_assurance_required', 'disallowed_by_account_manager',
  'disallowed_by_user_setting:music-video-disabled', 'disallowed_by_user_setting:other-video-disabled', 'watchability_restricted'};
const _signals = {'switch-to-video', 'switch-to-audio', 'switch-to-full-episode', 'jump', 'automix-preview', 'stop-automix-preview', 'plus', 'minus'};
List<String> _normalizeReasons(Iterable<String> values) => values.map((reason) => _reasons.contains(reason) ? reason : 'unknown').toList();

PlaybackJson _projectRestrictions(wire.Restrictions? restrictions) {
  final reasons = <String, Iterable<String>>{
    'Pausing': restrictions?.disallowPausingReasons ?? [],
    'Resuming': restrictions?.disallowResumingReasons ?? [],
    'Seeking': restrictions?.disallowSeekingReasons ?? [],
    'SkippingPrevious': restrictions?.disallowSkippingPrevReasons ?? [],
    'SkippingNext': restrictions?.disallowSkippingNextReasons ?? [],
    'TogglingRepeatContext': restrictions?.disallowTogglingRepeatContextReasons ?? [],
    'TogglingRepeatTrack': restrictions?.disallowTogglingRepeatTrackReasons ?? [],
    'TogglingShuffle': restrictions?.disallowTogglingShuffleReasons ?? [],
    'TransferringPlayback': restrictions?.disallowTransferringPlaybackReasons ?? [],
    'AddToQueue': restrictions?.disallowAddToQueueReasons ?? [],
    'SetQueue': restrictions?.disallowSetQueueReasons ?? [],
    'SettingPlaybackSpeed': restrictions?.disallowSettingPlaybackSpeedReasons ?? [],
  };
  final shuffle = reasons['TogglingShuffle']!.isEmpty;
  return {'canPause': reasons['Pausing']!.isEmpty, 'canResume': reasons['Resuming']!.isEmpty,
    'canSeek': reasons['Seeking']!.isEmpty, 'canSkipPrevious': reasons['SkippingPrevious']!.isEmpty,
    'canSkipNext': reasons['SkippingNext']!.isEmpty, 'canToggleRepeatContext': reasons['TogglingRepeatContext']!.isEmpty,
    'canToggleRepeatTrack': reasons['TogglingRepeatTrack']!.isEmpty, 'canToggleShuffle': shuffle,
    'canToggleSmartShuffle': shuffle && (restrictions?.disallowSettingModes['context_enhancement']?.values['RECOMMENDATION']?.reasons.where((reason) => reason != 'already_set').isEmpty ?? true),
    for (final entry in reasons.entries) 'disallow${entry.key}Reasons': _normalizeReasons(entry.value),
    'disallowSignals': {for (final entry in restrictions?.disallowSignals.entries ?? <MapEntry<String, wire.RestrictionReasons>>[])
      if (_signals.contains(entry.key)) entry.key: {'reasons': _normalizeReasons(entry.value.reasons)}}};
}

class PlaybackServiceException implements Exception {
  PlaybackServiceException(this.code, List<String> reasons) : reasons = List.unmodifiable(reasons);
  final String code;
  final List<String> reasons;
  String get message => reasons.isEmpty ? "Code '$code'" : "Code '$code' with reasons '${reasons.join(', ')}'";
  PlaybackJson toJson() => {'code': code, 'reasons': reasons, 'message': message};
  @override
  String toString() => message;

  factory PlaybackServiceException.fromMessage(wire.ContextPlayerError error) {
    final number = error.unknownFields.hasField(1) ? -1 : error.code.value;
    final code = switch (number) {
      25 => 'video_georestricted', 48 => 'audio_format_negotiation_fail', 47 => 'client_version_sunsetted',
      37 || 38 || 39 || 40 || 42 || 43 || 44 || 45 || 46 || -1 => 'unrecognized',
      _ => error.code.name.toLowerCase(),
    };
    final reasons = error.data['reasons'];
    return PlaybackServiceException(code, reasons == null || reasons.isEmpty ? [] : reasons.split(','));
  }
}
