import 'package:cancellation_token/cancellation_token.dart';

import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import 'controller.dart';
import 'models.dart';
import 'repository.dart';
import 'view.dart';

@Preview(name: 'Desktop search', group: 'Search', size: Size(640, 560))
@Preview(name: 'Narrow search', group: 'Search', size: Size(320, 480))
Widget searchPreview() => const _SearchPreview();

class _EmptyRepository implements SearchRepository {
  @override
  Future<SearchPage> recent({CancellationToken? cancellationToken}) async => SearchPage(query: '', items: []);

  @override
  Future<SearchPage> suggestions(String query, {CancellationToken? cancellationToken}) async => SearchPage(query: query, items: []);
}

class _SearchPreview extends StatefulWidget {
  const _SearchPreview();

  @override
  State<_SearchPreview> createState() => _SearchPreviewState();
}

class _SearchPreviewState extends State<_SearchPreview> {
  final controller = DesktopSearchController(_EmptyRepository());

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: ThemeData.dark(),
    home: Scaffold(body: SearchView(controller: controller, onSelect: (_) {})),
  );

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }
}
