import 'package:cancellation_token/cancellation_token.dart';

abstract interface class SavedPlaylistsRepository {
  Future<bool> containsPlaylist(String uri, {CancellationToken? cancellationToken});
  Future<void> setPlaylistSaved(String uri, bool saved, {CancellationToken? cancellationToken});
}
