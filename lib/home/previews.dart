import 'package:cancellation_token/cancellation_token.dart';

import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import 'home.dart';

@Preview(name: 'Desktop Home empty state', group: 'Home', size: Size(960, 640))
@Preview(name: 'Narrow Home empty state', group: 'Home', size: Size(320, 480))
Widget homePreview() => const _HomePreview();

class _EmptyRepository implements HomeRepository {
  @override
  Future<HomePage> load({String facet = '', CancellationToken? cancellationToken}) async => HomePage();
}

class _HomePreview extends StatefulWidget {
  const _HomePreview();
  @override
  State<_HomePreview> createState() => _HomePreviewState();
}

class _HomePreviewState extends State<_HomePreview> {
  final controller = HomeController(_EmptyRepository());

  @override
  Widget build(BuildContext context) => MaterialApp(theme: ThemeData.dark(),
    home: Scaffold(body: HomeView(controller: controller, onSelect: (_) {})));

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }
}
