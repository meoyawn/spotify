import 'dart:async';

import 'package:cancellation_token/cancellation_token.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/app/track_save_button.dart';
import 'package:spotify_flutter/library/saved_tracks.dart';
import 'package:spotify_flutter/library/saved_tracks_controller.dart';

void main() {
  testWidgets('save controls share immediate changes, coalesce reversals and restore acknowledged membership on failure', (tester) async {
    const uri = 'spotify:track:0000000000000000000001';
    final repository = _SavedTracks();
    final controller = SavedTracksController(repository);
    final errors = <Object>[];
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(home: Row(children: [
      for (var index = 0; index < 3; index++) TrackSaveButton(
        controller: controller, uri: uri, onError: errors.add),
    ])));
    await tester.pumpAndSettle();
    expect(repository.reads, 1);

    await tester.tap(find.byTooltip('Add to Liked Songs').first);
    await tester.pump();
    expect(find.byTooltip('Remove from Liked Songs'), findsNWidgets(3));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(repository.writes, [true]);

    await tester.tap(find.byTooltip('Remove from Liked Songs').last);
    await tester.pump();
    expect(find.byTooltip('Add to Liked Songs'), findsNWidgets(3));
    await tester.tap(find.byTooltip('Add to Liked Songs').at(1));
    await tester.pump();
    expect(find.byTooltip('Remove from Liked Songs'), findsNWidgets(3));
    repository.receipts.single.complete();
    await tester.pumpAndSettle();
    expect(repository.writes, [true]);
    expect(controller.state(uri).changing, isFalse);

    await tester.tap(find.byTooltip('Remove from Liked Songs').last);
    await tester.pump();
    expect(find.byTooltip('Add to Liked Songs'), findsNWidgets(3));
    repository.receipts.last.completeError(StateError('Rejected removal'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Remove from Liked Songs'), findsNWidgets(3));
    expect(errors, hasLength(1));
    expect(repository.writes, [true, false]);
    expect(repository.reads, 1);

    await tester.tap(find.byTooltip('Remove from Liked Songs').first);
    await tester.pump();
    await tester.tap(find.byTooltip('Add to Liked Songs').last);
    await tester.pump();
    expect(find.byTooltip('Remove from Liked Songs'), findsNWidgets(3));
    repository.receipts.last.complete();
    await tester.pump();
    expect(repository.writes, [true, false, false, true]);
    repository.receipts.last.completeError(StateError('Rejected reversal'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Add to Liked Songs'), findsNWidgets(3));
    expect(controller.state(uri).changing, isFalse);
    expect(errors, hasLength(2));
  });
}

class _SavedTracks implements SavedTracksRepository {
  var reads = 0;
  final writes = <bool>[];
  final receipts = <Completer<void>>[];
  @override Future<Map<String, bool>> contains(List<String> uris, {CancellationToken? cancellationToken}) async {
    reads++;
    return {for (final uri in uris) uri: false};
  }
  @override Future<void> setSaved(String uri, bool saved, {CancellationToken? cancellationToken}) {
    writes.add(saved);
    final receipt = Completer<void>();
    receipts.add(receipt);
    return receipt.future.asCancellable(cancellationToken);
  }
}
