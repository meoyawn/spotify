import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:cancellation_token/cancellation_token.dart';

import '../playback/controller.dart';
import '../playback/models.dart';

/// Flutter owns the menu, actual player-state projection and every action.
/// tray_manager0.5.2 supplies the standard macOS status-item primitive only.
class DesktopTray with TrayListener {
  DesktopTray._({required this.controller, required this.toggle,
    required this.previous, required this.next, required this.onError,
    CancellationToken? cancellationToken}) : _parentCancellation = cancellationToken;

  static const _desktop = MethodChannel('spotify_flutter/desktop_host');
  final PlaybackController controller;
  final Future<void> Function() toggle, previous, next;
  final void Function(Object error) onError;
  final CancellationToken? _parentCancellation;
  CancellationToken? _cancellation;
  CancellationToken get _token => _cancellation ??= MergedCancellationToken([?_parentCancellation]);
  StreamSubscription<PlaybackState>? _states;
  Future<void> _menuWrites = Future<void>.value();
  String? _menuKey;
  bool _closed = false, _iconCreated = false;
  Future<void>? _closing;

  /// A currently running app predating plugin registration keeps its session:
  /// MissingPluginException simply defers the icon until the native rebuild.
  static Future<DesktopTray?> open({required PlaybackController controller,
    required Future<void> Function() toggle,
    required Future<void> Function() previous,
    required Future<void> Function() next,
    required void Function(Object error) onError, CancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    if (!Platform.isMacOS) return null;
    final tray = DesktopTray._(controller: controller, toggle: toggle,
      previous: previous, next: next, onError: onError, cancellationToken: cancellationToken);
    trayManager.addListener(tray);
    try {
      await trayManager.setIcon('assets/app-shell/icons/tray.png', isTemplate: true, iconSize: 18);
      tray._iconCreated = true;
      tray._token.throwIfCancelled();
      tray._states = controller.states.listen(tray._update, onError: tray._report);
      tray._update(controller.state);
      await tray._menuWrites;
      tray._token.throwIfCancelled();
      return tray;
    } on MissingPluginException {
      await tray.close();
      return null;
    } catch (_) {
      await tray.close();
      rethrow;
    }
  }

  void _update(PlaybackState? state) {
    if (_closed || _token.isCancelled) return;
    final active = state != null && (state.hasContext ||
      (state.item != null && !state.isBuffering));
    final paused = state?.isPaused ?? true;
    final canToggle = active && (paused
      ? state.restrictions.canResume : state.restrictions.canPause);
    final canPrevious = active && state.restrictions.canSkipPrevious;
    final canNext = active && state.restrictions.canSkipNext;
    final title = state?.item?.name ?? '';
    // Position frames do not recreate the user's open menu.
    final key = '$paused|$canToggle|$canPrevious|$canNext|$title';
    if (key == _menuKey) return;
    _menuKey = key;
    final menu = Menu(items: [
      MenuItem(key: 'show', label: 'Show Spotify'),
      MenuItem.separator(),
      MenuItem(key: 'toggle', label: paused ? 'Play' : 'Pause', disabled: !canToggle),
      MenuItem(key: 'previous', label: 'Previous', disabled: !canPrevious),
      MenuItem(key: 'next', label: 'Next', disabled: !canNext),
      MenuItem.separator(),
      MenuItem(key: 'quit', label: 'Quit Spotify'),
    ]);
    _menuWrites = _menuWrites.then<void>((_) async {
      if (_closed || _token.isCancelled) return;
      await trayManager.setToolTip(title.isEmpty ? 'Spotify' : '$title — Spotify');
      if (!_closed && !_token.isCancelled) await trayManager.setContextMenu(menu);
    }).catchError(_report);
  }

  void _report(Object error) { if (!_closed && !_token.isCancelled) onError(error); }

  void _perform(Future<void> Function() action) {
    if (_closed || _token.isCancelled) return;
    unawaited(Future<void>.sync(action).catchError(_report));
  }

  @override
  void onTrayIconMouseDown() => _perform(() => trayManager.popUpContextMenu());

  @override
  void onTrayIconRightMouseDown() => _perform(() => trayManager.popUpContextMenu());

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show': _perform(() => _desktop.invokeMethod<void>('showWindow'));
      case 'toggle': _perform(toggle);
      case 'previous': _perform(previous);
      case 'next': _perform(next);
      case 'quit': _perform(() => _desktop.invokeMethod<void>('quit'));
    }
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    _token.cancel();
    trayManager.removeListener(this);
    await _states?.cancel();
    await _menuWrites;
    if (_iconCreated) {
      try { await trayManager.destroy(); }
      on MissingPluginException { /* The current runner may predate this plugin. */ }
    }
  }
}
