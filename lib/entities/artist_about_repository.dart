import 'dart:async';

import 'package:cancellation_token/cancellation_token.dart';
import 'package:flutter/foundation.dart';

import '../async/shared_task.dart';
import 'models.dart';

/// The sidebar and artist route share the original overview read, without
/// loading popular tracks or discography just to show the biography.
class ArtistAboutRepository extends ChangeNotifier {
  ArtistAboutRepository({required this.readOverview, required this.contains,
    required Future<void> Function(String uri, bool following, {CancellationToken? cancellationToken}) setFollowing})
    // ignore: prefer_initializing_formals
    : _setFollowing = setFollowing;
  final Future<EntityJson> Function(String uri, {CancellationToken? cancellationToken}) readOverview;
  final Future<bool> Function(String uri, {CancellationToken? cancellationToken}) contains;
  final Future<void> Function(String uri, bool following, {CancellationToken? cancellationToken}) _setFollowing;
  final _following = <String, ({bool value, int revision})>{};
  final _changing = <String>{};
  final _followWrites = <String, Future<void>>{};
  final _followCancellation = CancellationToken();
  int _followRevision = 0;
  bool _disposed = false;
  final _overviews = <String, ({SharedTask<EntityJson> task, DateTime expires})>{};

  bool? following(String uri) => _following[uri]?.value;
  bool changingFollowing(String uri) => _changing.contains(uri);

  Future<void> loadFollowing(String uri, {CancellationToken? cancellationToken}) async {
    final revision = _following[uri]?.revision ?? 0;
    final value = await contains(uri, cancellationToken: cancellationToken);
    cancellationToken?.throwIfCancelled();
    if (_disposed || _changing.contains(uri) || (_following[uri]?.revision ?? 0) != revision) return;
    _rememberFollowing(uri, value, revision);
    notifyListeners();
  }

  Future<void> setFollowing(String uri, bool following,
      {CancellationToken? cancellationToken, VoidCallback? onLibraryChanged}) async {
    cancellationToken?.throwIfCancelled();
    if (_disposed) throw StateError('Spotify session changed');
    if (this.following(uri) == null) await loadFollowing(uri, cancellationToken: cancellationToken);
    cancellationToken?.throwIfCancelled();
    if (_disposed) throw StateError('Spotify session changed');
    final acknowledged = this.following(uri)!;
    final pending = _followWrites[uri];
    if (following == acknowledged) {
      if (pending != null) await pending.asCancellable(cancellationToken);
      return;
    }
    _changing.add(uri);
    _rememberFollowing(uri, following, ++_followRevision);
    if (pending != null) {
      notifyListeners();
      await pending.asCancellable(cancellationToken);
      return;
    }
    final write = _followWrites[uri] = Future<void>.microtask(() =>
      _writeFollowing(uri, acknowledged, onLibraryChanged));
    unawaited(write.catchError((Object _) {}));
    notifyListeners();
    await write.asCancellable(cancellationToken);
  }

  Future<void> _writeFollowing(String uri, bool acknowledged, VoidCallback? onLibraryChanged) async {
    var changed = false;
    try {
      while (following(uri) != acknowledged) {
        _followCancellation.throwIfCancelled();
        final desired = following(uri)!;
        await _setFollowing(uri, desired, cancellationToken: _followCancellation);
        if (_disposed) return;
        acknowledged = desired;
        changed = true;
      }
    } finally {
      _followWrites.remove(uri);
      _changing.remove(uri);
      if (!_disposed) {
        _rememberFollowing(uri, acknowledged, ++_followRevision);
        notifyListeners();
        if (changed) onLibraryChanged?.call();
      }
    }
  }

  void _rememberFollowing(String uri, bool value, int revision) {
    _following.remove(uri);
    _following[uri] = (value: value, revision: revision);
    while (_following.length > 16) {
      final evict = _following.keys.where((key) => !_changing.contains(key)).firstOrNull;
      if (evict == null) break;
      _following.remove(evict);
    }
  }

  @override
  void dispose() { _disposed = true; _followCancellation.cancel(); super.dispose(); }

  Future<EntityJson> overview(String uri, {CancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    if (!RegExp(r'^spotify:artist:[0-9A-Za-z]{22}$').hasMatch(uri)) {
      throw ArgumentError.value(uri, 'uri', 'Expected a Spotify artist');
    }
    var cached = _overviews.remove(uri);
    if (cached == null || cached.task.token.isCancelled || !cached.expires.isAfter(DateTime.now())) {
      cached = (task: SharedTask((token) => readOverview(uri, cancellationToken: token)),
        expires: DateTime.now().add(const Duration(minutes: 5)));
    }
    _overviews[uri] = cached;
    while (_overviews.length > 16) { _overviews.remove(_overviews.keys.first); }
    try { return await cached.task.wait(cancellationToken); }
    catch (error) {
      if ((error is! CancelledException || cached.task.token.isCancelled) &&
          identical(_overviews[uri]?.task, cached.task)) { _overviews.remove(uri); }
      rethrow;
    }
  }

  Future<EntityDetails?> artist(String uri, {CancellationToken? cancellationToken}) async {
    final response = await overview(uri, cancellationToken: cancellationToken);
    final artist = (response['data'] as Map?)?['artistUnion'];
    if (artist is! Map || artist['__typename'] != 'Artist') return null;
    final profile = artist['profile'] as Map?, visuals = artist['visuals'] as Map?;
    final biography = (profile?['biography'] as Map?)?['text'] as String? ?? '';
    final name = profile?['name'] as String? ?? '';
    if (name.isEmpty || biography.trim().isEmpty) return null;
    final gallery = (visuals?['gallery'] as Map?)?['items'] as List? ?? const [];
    List<EntityJson> sources(Object? value) => (value as List? ?? const [])
      .whereType<Map>().map((image) => image.cast<String, Object?>())
      .where((image) => image['url'] is String && (image['url'] as String).isNotEmpty).toList();
    final wide = gallery.whereType<Map>().map((group) => sources(group['sources']))
      .where((group) => group.any((image) => image['width'] is num && image['height'] is num &&
        (image['width'] as num) >= (image['height'] as num))).firstOrNull;
    return EntityDetails.fromJson({'type': 'artist', 'uri': uri, 'name': name,
      'biography': biography, 'stats': artist['stats'], 'hasGallery': wide != null,
      'images': wide ?? sources((visuals?['avatarImage'] as Map?)?['sources'])});
  }
}
