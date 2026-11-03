import '../protocol/generated/lens-model.pb.dart';
import '../protocol/generated/playlist_api.pb.dart';

/// The revision/cache-owner part of a live native playlist context.
/// This value does not contain the list's row tree or attribute transaction.
class PlaylistSnapshotRevisionState {
  PlaylistSnapshotRevisionState({required List<int> revision,
    List<LensState> revisionLenses = const [], List<Delta> pendingChanges = const [],
    List<Op> stagedOperations = const [], this.headless = false,
    this.dropPendingChangesOnSnapshot = false, int contentGenerationVersion = 0})
    : revision = List.unmodifiable(revision),
      revisionLenses = List.unmodifiable([for (final value in revisionLenses) value.deepCopy()..freeze()]),
      pendingChanges = List.unmodifiable([for (final value in pendingChanges) value.deepCopy()..freeze()]),
      stagedOperations = List.unmodifiable([for (final value in stagedOperations) value.deepCopy()..freeze()]),
      contentGenerationVersion = contentGenerationVersion.toUnsigned(32);

  final List<int> revision;
  /// Full revision-attached LensState messages, including HTTP410 states.
  /// Effective URI/requested-lens reconciliation has a separate owner.
  final List<LensState> revisionLenses;
  final List<Delta> pendingChanges;
  final List<Op> stagedOperations;
  final bool headless;
  final bool dropPendingChangesOnSnapshot;
  final int contentGenerationVersion;
}

class PlaylistSnapshotRevisionResult {
  const PlaylistSnapshotRevisionResult({required this.applied, required this.state});
  final bool applied;
  final PlaylistSnapshotRevisionState state;
}

/// Original101abf8dc revision/cache-owner transition, with101ac3c28 headless
/// bookkeeping. The caller must own a live context and complete its list data
/// transaction before adopting this result or persisting a cache snapshot.
/// This function does not mutate rows/attributes, dispatch notifications, write
/// a store or implement the outer pending-change/HTTP error admission rules.
PlaylistSnapshotRevisionResult advancePlaylistFullSnapshotRevision(
  PlaylistSnapshotRevisionState current, SelectedListContent reply,
  {int? contentGenerationVersion}) {
  if (reply.hasDiff() || reply.hasSyncResult()) {
    throw UnsupportedError('Delta and sync-result replies require the native delta application owner.');
  }
  // protobuf6.1.0's generated hasRevision() treats every empty List as absent.
  // Proto2 bytes retain explicit empty presence in the public stored-field API.
  if (reply.getFieldOrNull(1) == null) {
    return PlaylistSnapshotRevisionResult(applied: false, state: current);
  }
  reply.check();
  final List<int> revision;
  final List<LensState> lenses;
  if (!reply.hasContents()) {
    revision = const [0, 0, 0, 0, 0x72, 0x6f, 0x6f, 0x74];
    lenses = const [];
  } else {
    revision = reply.revision;
    lenses = reply.hasAppliedLenses() ? reply.appliedLenses.states : current.revisionLenses;
  }
  final pending = current.dropPendingChangesOnSnapshot ? <Delta>[] : current.pendingChanges;
  final staged = current.dropPendingChangesOnSnapshot ? <Op>[] : current.stagedOperations;
  var headless = current.headless;
  var dropPending = false;
  if (headless && pending.isEmpty && staged.isEmpty) {
    headless = false;
    dropPending = true;
  }
  return PlaylistSnapshotRevisionResult(applied: true,
    state: PlaylistSnapshotRevisionState(revision: revision, revisionLenses: lenses,
      pendingChanges: pending, stagedOperations: staged, headless: headless,
      dropPendingChangesOnSnapshot: dropPending,
      contentGenerationVersion: contentGenerationVersion ?? current.contentGenerationVersion));
}
