import 'package:cancellation_token/cancellation_token.dart';

import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import 'entities.dart';

@Preview(name: 'Entity unavailable', group: 'Entities', size: Size(900, 640))
@Preview(name: 'Entity unavailable narrow', group: 'Entities', size: Size(320, 480), textScaleFactor: 1.5)
Widget entityPreview() => const _EntityPreview();

class _UnavailableRepository implements EntityRepository {
  @override
  Future<EntityPage> open(String uri, {CancellationToken? cancellationToken}) async => throw const EntityQueryError(null);
  @override
  Future<EntityTrackPage> tracks(EntityDetails details, {required int offset, int? limit, CancellationToken? cancellationToken}) async =>
    throw const EntityQueryError(null);
}

class _EntityPreview extends StatefulWidget {
  const _EntityPreview();
  @override
  State<_EntityPreview> createState() => _EntityPreviewState();
}

class _EntityPreviewState extends State<_EntityPreview> {
  final controller = EntityController(_UnavailableRepository(), uri: 'spotify:album:unavailable');
  @override
  Widget build(BuildContext context) => MaterialApp(theme: ThemeData.dark(),
    home: Scaffold(body: EntityView(controller: controller)));
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }
}
