import 'package:fixnum/fixnum.dart';

import '../protocol/generated/es_context.pb.dart' as wire;
import '../protocol/generated/es_context_page.pb.dart' as wire;
import '../protocol/generated/es_context_player_options.pb.dart' as wire;
import '../protocol/generated/es_context_track.pb.dart' as wire;
import '../protocol/generated/es_optional.pb.dart' as wire;
import '../protocol/generated/es_play_origin.pb.dart' as wire;
import '../protocol/generated/es_prepare_play_options.pb.dart' as wire;
import '../protocol/generated/es_restrictions.pb.dart' as wire;
import '../protocol/generated/es_skip_to_track.pb.dart' as wire;

enum PlaybackRepeat { none, context, track }

class PlaybackItemReference {
  const PlaybackItemReference(this.uri, {this.uid, this.metadata = const {}});
  final String uri;
  final String? uid;
  final Map<String, String> metadata;

  wire.ContextTrack toMessage() => wire.ContextTrack(
    uri: nonempty(uri), uid: nonempty(uid), metadata: metadata.entries,
  );
}

class PlaybackPage {
  const PlaybackPage({this.uri, this.url, this.nextPageUrl, this.items,
    this.metadata = const {}});
  final String? uri, url, nextPageUrl;
  final List<PlaybackItemReference>? items;
  final Map<String, String> metadata;

  wire.ContextPage toMessage() {
    if (url != null) {
      final pageMetadata = {...metadata}..remove('page_uri');
      if (uri != null) pageMetadata['page_uri'] = uri!;
      return wire.ContextPage(pageUrl: nonempty(url),
        nextPageUrl: nonempty(nextPageUrl), isLoading: true,
        metadata: pageMetadata.entries);
    }
    if (items != null) {
      return wire.ContextPage(tracks: items!.map((item) => item.toMessage()),
        metadata: metadata.entries, nextPageUrl: nonempty(nextPageUrl));
    }
    throw ArgumentError("Invalid 'ContextPage' provided! Either 'url' or 'items' needs to be set.");
  }
}

/// ContextPlayer's ordinary context path; playlist service routing is separate.
class PlaybackContext {
  const PlaybackContext(this.uri, {this.url, this.pages,
    this.metadata = const {}, this.restrictions});
  final String uri;
  final String? url;
  final List<PlaybackPage>? pages;
  final Map<String, String> metadata;
  final wire.Restrictions? restrictions;

  wire.Context toMessage() => wire.Context(
    uri: nonempty(uri), url: pages == null ? nonempty(url ?? 'context://$uri') : nonempty(url),
    pages: pages?.map((page) => page.toMessage()), metadata: metadata.entries,
    isLoading: pages == null ? true : null,
    restrictions: wire.Restrictions(
      disallowPausingReasons: restrictions?.disallowPausingReasons,
      disallowResumingReasons: restrictions?.disallowResumingReasons,
      disallowSeekingReasons: restrictions?.disallowSeekingReasons,
      disallowSkippingPrevReasons: restrictions?.disallowSkippingPrevReasons,
      disallowSkippingNextReasons: restrictions?.disallowSkippingNextReasons,
      disallowTogglingRepeatContextReasons: restrictions?.disallowTogglingRepeatContextReasons,
      disallowTogglingRepeatTrackReasons: restrictions?.disallowTogglingRepeatTrackReasons,
      disallowTogglingShuffleReasons: restrictions?.disallowTogglingShuffleReasons,
      disallowSettingPlaybackSpeedReasons: restrictions?.disallowSettingPlaybackSpeedReasons,
    ),
  );
}

class PlaybackOrigin {
  const PlaybackOrigin({this.featureIdentifier = '', this.featureVersion = '',
    this.referrerIdentifier = '', this.viewURI = '', this.externalReferrer = '',
    this.restrictionIdentifier = ''});
  final String featureIdentifier, featureVersion, referrerIdentifier, viewURI,
      externalReferrer, restrictionIdentifier;

  wire.PlayOrigin toMessage() => wire.PlayOrigin(
    featureIdentifier: nonempty(featureIdentifier), featureVersion: nonempty(featureVersion),
    referrerIdentifier: nonempty(referrerIdentifier), viewUri: nonempty(viewURI),
    externalReferrer: nonempty(externalReferrer), restrictionIdentifier: nonempty(restrictionIdentifier),
  );
}

class PlaybackSkipTarget {
  const PlaybackSkipTarget({this.pageURL, this.pageIndex, this.uid, this.uri, this.index});
  final String? pageURL, uid, uri;
  final int? pageIndex, index;

  wire.SkipToTrack toMessage() => wire.SkipToTrack(
    pageUrl: nonempty(pageURL), pageIndex: pageIndex == null ? null : optionalInt(pageIndex!),
    trackUid: nonempty(uid), trackUri: nonempty(uri),
    trackIndex: index == null ? null : optionalInt(index!),
  );
}

class PlaybackLogging {
  const PlaybackLogging({this.interactionId, this.pageInstanceId, this.commandId});
  final String? interactionId, pageInstanceId, commandId;
}

class PlaybackOptions {
  const PlaybackOptions({this.skipTo, this.seekTo, this.shuffle, this.repeat,
    this.playbackSpeed, this.modes = const {}, this.playbackId,
    this.alwaysPlaySomething = false, this.paused = false, this.sessionId,
    this.loggingParams});
  final PlaybackSkipTarget? skipTo;
  final int? seekTo;
  final bool? shuffle;
  final PlaybackRepeat? repeat;
  final double? playbackSpeed;
  final Map<String, String> modes;
  final List<int>? playbackId;
  final bool alwaysPlaySomething, paused;
  final String? sessionId;
  final PlaybackLogging? loggingParams;

  wire.PreparePlayOptions toMessage(PlaybackContext context) {
    final show = playbackUriType(context.uri) == 'show';
    final overrides = wire.ContextPlayerOptionOverrides(modes: modes.entries,
      playbackSpeed: playbackSpeed);
    if (shuffle != null || show) overrides.shufflingContext = optionalBool(shuffle ?? false);
    if (repeat != null || show) {
      overrides.repeatingContext = optionalBool(repeat != null && repeat != PlaybackRepeat.none);
      overrides.repeatingTrack = optionalBool(repeat == PlaybackRepeat.track);
    }
    return wire.PreparePlayOptions(skipTo: skipTo?.toMessage(),
      seekTo: seekTo == null ? null : optionalInt(seekTo!),
      playerOptionsOverride: overrides,
      playbackId: playbackId?.isNotEmpty == true ? playbackId : null,
      alwaysPlaySomething: alwaysPlaySomething ? true : null,
      initiallyPaused: paused ? true : null, sessionId: nonempty(sessionId));
  }
}

String? nonempty(String? value) => value == null || value.isEmpty ? null : value;
wire.OptionalBoolean optionalBool(bool value) => wire.OptionalBoolean(value: value ? true : null);
wire.OptionalInt64 optionalInt(int value) => wire.OptionalInt64(value: value == 0 ? null : Int64(value));

/// Canonical internal URIs and their ordinary web-link equivalents.
String? playbackUriType(String value) {
  var text = value;
  if (text.startsWith('spotify:')) {
    text = text.substring(8);
  } else {
    final web = RegExp(r'^https?://(?:open|play)\.spotify\.com/').firstMatch(text);
    if (web != null) {
      text = text.substring(web.end).replaceAll('/', ':');
    } else if (text.startsWith('/')) {
      text = text.substring(1).replaceAll('/', ':');
    } else {
      return null;
    }
  }
  text = text.split('?').first.split('#').first;
  final components = text.split(':');
  final type = components.first;
  if (type == 'ad') return type;
  if (type == 'local') return components.length >= 5 ? type : null;
  if (const {'track', 'album', 'artist', 'playlist', 'episode', 'show',
      'kallax', 'podcast-chapter', 'clip'}.contains(type) && components.length >= 2 &&
      RegExp(r'^[a-zA-Z0-9]{22}$').hasMatch(components[1])) {
    return type;
  }
  return null;
}
