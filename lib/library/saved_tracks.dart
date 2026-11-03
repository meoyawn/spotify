import 'package:cancellation_token/cancellation_token.dart';

/// Saved-track membership belongs to the authenticated account, independently
/// of which playlist, player or detail view displays a track.
abstract interface class SavedTracksRepository {
  Future<Map<String, bool>> contains(List<String> uris, {CancellationToken? cancellationToken});
  Future<void> setSaved(String uri, bool saved, {CancellationToken? cancellationToken});
}
