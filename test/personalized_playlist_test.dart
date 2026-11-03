import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/entities/controller.dart';
import 'package:spotify_flutter/entities/models.dart';
import 'package:spotify_flutter/entities/native_playlist_repository.dart';
import 'package:spotify_flutter/entities/view.dart';
import 'package:spotify_flutter/protocol/generated/playlist_api.pb.dart' as playlist;

void main() {
  testWidgets('native playlists prefer desktop banners, fall back to mobile, honor recipient visibility and retain ordinary covers', (tester) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = NativePlaylistEntityRepository(imageUrlTemplate: 'https://fixture.invalid/{file_id}',
      read: (uri, {cancellationToken}) async => playlist.SelectedListContent(
        ownerUsername: 'spotify', length: 1,
        attributes: playlist.ListAttributes(name: 'Provided playlist', description: 'A real playlist description',
          format: uri.split(':').last,
          pictureSize: [playlist.PictureSize(targetName: 'default', url: 'https://fixture.invalid/cover')],
          formatAttributes: [if (!uri.endsWith('ordinary')) ...[
            playlist.FormatListAttribute(key: 'header_image_url_desktop',
              value: uri.endsWith('release-radar') ? '' : 'https://fixture.invalid/banner'),
            playlist.FormatListAttribute(key: 'image_url', value: 'https://fixture.invalid/mobile'),
            playlist.FormatListAttribute(key: 'madeFor.username', value: 'listener'),
            playlist.FormatListAttribute(key: 'madeFor.displayed', value: uri.endsWith('daily-mix') ? '0' : '1'),
          ]]), contents: playlist.ListItems(items: [playlist.Item(uri: 'spotify:track:0000000000000000000001')])),
      describeTracks: (uris, {cancellationToken}) async => {
        for (final uri in uris) uri: EntityRow.fromJson({'type': 'track', 'uri': uri,
          'name': 'Provided song', 'artists': <EntityJson>[], 'duration': {'milliseconds': 180000},
          'canRequestPlayback': true}),
      });
    final controller = EntityController(repository, uri: 'spotify:playlist:discover-weekly');
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(), home: Scaffold(body: EntityView(
      controller: controller, artworkBuilder: (_, entity) => ColoredBox(
        key: ValueKey('artwork:${entity.images.firstOrNull?['url']}'), color: const Color(0xff334455)),
    ))));
    await tester.pumpAndSettle();
    for (final format in ['discover-weekly', 'release-radar', 'daily-mix']) {
      if (format != 'discover-weekly') await controller.setUri('spotify:playlist:$format');
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('artwork:https://fixture.invalid/${format == 'release-radar' ? 'mobile' : 'banner'}')), findsOneWidget);
      expect(find.byKey(const ValueKey('artwork:https://fixture.invalid/cover')), findsNothing);
      expect(find.textContaining('Made for'), format == 'daily-mix' ? findsNothing : findsOneWidget);
      expect(find.textContaining('listener'), format == 'daily-mix' ? findsNothing : findsOneWidget);
      expect(find.text('A real playlist description'), findsOneWidget);
      expect(find.text('Provided song'), findsOneWidget);
    }
    tester.view.physicalSize = const Size(320, 640);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('artwork:https://fixture.invalid/banner')), findsOneWidget);
    await controller.setUri('spotify:playlist:ordinary');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('artwork:https://fixture.invalid/cover')), findsOneWidget);
    expect(find.byKey(const ValueKey('artwork:https://fixture.invalid/banner')), findsNothing);
    expect(find.textContaining('Made for'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
