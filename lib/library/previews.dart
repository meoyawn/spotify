import 'package:cancellation_token/cancellation_token.dart';

import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import 'library.dart';

@Preview(name: 'Library empty state', group: 'Library', size: Size(320, 640))
@Preview(name: 'Wide Library empty state', group: 'Library', size: Size(800, 640))
Widget libraryPreview() => const _LibraryPreview();

class _EmptyRepository implements LibraryRepository {
  @override
  Future<LibraryPage> load(LibraryQuery query, {CancellationToken? cancellationToken}) async => LibraryPage();
}

class _LibraryPreview extends StatefulWidget {
  const _LibraryPreview();
  @override
  State<_LibraryPreview> createState() => _LibraryPreviewState();
}

class _LibraryPreviewState extends State<_LibraryPreview> {
  final controller = LibraryController(_EmptyRepository());
  @override
  Widget build(BuildContext context) => MaterialApp(theme: ThemeData.dark(),
    home: Scaffold(body: LibraryView(controller: controller, onSelect: (_) {})));
  @override
  void dispose() { controller.dispose(); super.dispose(); }
}
