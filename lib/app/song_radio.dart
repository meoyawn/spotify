import 'package:flutter/material.dart';

class SongRadioScope extends InheritedWidget {
  const SongRadioScope({super.key, required super.child, this.onOpen, this.loadingUri});
  final ValueChanged<String>? onOpen;
  final String? loadingUri;

  static SongRadioScope? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<SongRadioScope>();

  @override bool updateShouldNotify(SongRadioScope oldWidget) =>
    onOpen != oldWidget.onOpen || loadingUri != oldWidget.loadingUri;
}

PopupMenuItem<String>? songRadioMenuItem(BuildContext context, String uri) {
  if (!RegExp(r'^spotify:track:[0-9A-Za-z]{22}$').hasMatch(uri)) return null;
  final radio = SongRadioScope.maybeOf(context);
  if (radio == null) return null;
  final loading = radio.loadingUri == uri;
  return PopupMenuItem(value: 'radio', enabled: radio.onOpen != null && !loading,
    child: Text(loading ? 'Opening song radio…' : 'Go to song radio'));
}
