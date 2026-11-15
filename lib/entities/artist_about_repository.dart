import 'package:cancellation_token/cancellation_token.dart';

import '../async/shared_task.dart';
import 'models.dart';

/// The sidebar and artist route share the original overview read, without
/// loading popular tracks or discography just to show the biography.
class ArtistAboutRepository {
  ArtistAboutRepository({required this.readOverview, required this.contains,
    required this.setFollowing});
  final Future<EntityJson> Function(String uri, {CancellationToken? cancellationToken}) readOverview;
  final Future<bool> Function(String uri, {CancellationToken? cancellationToken}) contains;
  final Future<void> Function(String uri, bool following, {CancellationToken? cancellationToken}) setFollowing;
  final _overviews = <String, ({SharedTask<EntityJson> task, DateTime expires})>{};

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
