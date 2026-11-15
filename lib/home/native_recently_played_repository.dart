import 'package:cancellation_token/cancellation_token.dart';

import '../async/shared_task.dart';
import '../library/liked_songs.dart';
import '../protocol/generated/recently_played_backend.pb.dart';
import 'destinations_repository.dart';
import 'models.dart';
import 'native_recent_contexts.dart';

/// Original Recent Contexts order: newest first, unique URI, one Liked Songs
/// card. The fixed fifty-context response has no server pagination contract.
List<Context> orderedRecentContexts(RecentlyPlayed response) {
  final contexts = [...response.contexts]..sort((a, b) => b.lastPlayedTime.compareTo(a.lastPlayedTime));
  final seen = <String>{};
  return contexts.where((entry) => seen.add(_canonical(entry.uri))).toList(growable: false);
}

String _canonical(String uri) => uri == 'spotify:collection:tracks' ||
    RegExp(r'^spotify:user:[^:]+:collection$').hasMatch(uri) ? likedSongsUri : uri;

class NativeRecentlyPlayedRepository implements HomeDestinationRepository {
  NativeRecentlyPlayedRepository({required this.client, required this.describe});
  final NativeRecentContextsClient client;
  final Future<Map<String, HomeItem>> Function(List<String>, {CancellationToken? cancellationToken}) describe;
  NativeRecentContextsSnapshot? _snapshot;
  final _pages = <int, SharedTask<HomeDestinationPage>>{};

  @override
  Future<HomeDestinationPage> destination(HomeDestinationTarget target, {int offset = 0,
      CancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    if (target.kind != HomeDestinationKind.recentlyPlayed || offset < 0 || offset >= 50) {
      throw ArgumentError('Invalid Recently Played page');
    }
    final snapshot = await client.read(cancellationToken: cancellationToken);
    cancellationToken?.throwIfCancelled();
    if (!identical(snapshot, _snapshot)) {
      for (final page in _pages.values) { page.token.cancel(); }
      _pages.clear();
      _snapshot = snapshot;
    }
    if (_pages[offset]?.token.isCancelled == true) _pages.remove(offset);
    final task = _pages.putIfAbsent(offset, () => SharedTask((token) async {
      final contexts = orderedRecentContexts(snapshot.response);
      final selected = contexts.skip(offset).take(20).map((context) => _canonical(context.uri)).toList();
      final descriptions = await describe(selected, cancellationToken: token);
      token.throwIfCancelled();
      final next = offset + selected.length;
      return HomeDestinationPage(title: 'Recently played', fullPage: true,
        nextOffset: next < contexts.length ? next : null,
        sections: [HomeSection(uri: target.uri, kind: HomeSectionKind.carousel,
          sourceType: 'RecentContexts', items: [for (final uri in selected)
            if (uri == likedSongsUri) HomeItem(type: 'liked-songs', uri: uri,
              name: 'Liked Songs', images: likedSongsImages)
            else ?descriptions[uri]])]);
    }));
    try { return await task.wait(cancellationToken); }
    catch (_) {
      if ((task.isComplete || task.token.isCancelled) && identical(_pages[offset], task)) _pages.remove(offset);
      rethrow;
    }
  }
}
