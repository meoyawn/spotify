import 'dart:async';

import 'package:cancellation_token/cancellation_token.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Page-style zoom: layout uses a smaller viewport as the whole UI grows.
/// Keep this above the Navigator so dialogs, menus and hit testing zoom too.
class DesktopAppScale extends StatefulWidget {
  const DesktopAppScale({super.key, required this.child});
  final Widget child;

  @override
  State<DesktopAppScale> createState() => DesktopAppScaleState();
}

class DesktopAppScaleState extends State<DesktopAppScale> {
  static const _steps = <double>[.5, 2 / 3, .75, .8, .9, 1, 1.1, 1.25, 1.5, 1.75, 2];
  static const _preference = 'ui.scale';
  final _lifetime = CancellationToken();
  SharedPreferences? _preferences;
  int _step = 5;
  bool _edited = false;
  Timer? _saveTimer;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addEarlyKeyEventHandler(_handleKey);
    unawaited(_restore());
  }

  Future<void> _restore() async {
    try {
      final preferences = await SharedPreferences.getInstance().asCancellable(_lifetime);
      if (!mounted) return;
      _preferences = preferences;
      if (_edited) {
        unawaited(_save());
        return;
      }
      final saved = preferences.getDouble(_preference);
      if (saved == null || !saved.isFinite) return;
      var nearest = 0;
      for (var index = 1; index < _steps.length; index++) {
        if ((_steps[index] - saved).abs() < (_steps[nearest] - saved).abs()) nearest = index;
      }
      if (_step != nearest) setState(() => _step = nearest);
    } on CancelledException { /* The app closed while loading preferences. */ }
    on MissingPluginException { /* Standalone shells can have no native preferences. */ }
    on PlatformException catch (error) { debugPrint('App scale: ${error.message}'); }
  }

  void zoomIn() => _setStep(_step + 1);
  void zoomOut() => _setStep(_step - 1);
  void reset() => _setStep(5);

  void _setStep(int step) {
    step = step.clamp(0, _steps.length - 1);
    _edited = true;
    if (_step == step) return;
    setState(() => _step = step);
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 250), () => unawaited(_save()));
  }

  Future<void> _save() async {
    try { await _preferences?.setDouble(_preference, _steps[_step]); }
    on MissingPluginException { /* No native preferences in a standalone shell. */ }
    on PlatformException catch (error) { debugPrint('App scale: ${error.message}'); }
  }

  KeyEventResult _handleKey(KeyEvent event) {
    final keyboard = HardwareKeyboard.instance;
    if (event is KeyUpEvent || !keyboard.isMetaPressed || keyboard.isControlPressed ||
        keyboard.isAltPressed) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.equal || key == LogicalKeyboardKey.add ||
        key == LogicalKeyboardKey.numpadAdd || event.character == '+') {
      zoomIn();
    } else if (!keyboard.isShiftPressed &&
        (key == LogicalKeyboardKey.minus || key == LogicalKeyboardKey.numpadSubtract)) {
      zoomOut();
    } else if (!keyboard.isShiftPressed &&
        (key == LogicalKeyboardKey.digit0 || key == LogicalKeyboardKey.numpad0)) {
      reset();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    FocusManager.instance.removeEarlyKeyEventHandler(_handleKey);
    _lifetime.cancel();
    _saveTimer?.cancel();
    if (_edited) unawaited(_save());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, constraints) {
    final scale = _steps[_step];
    final media = MediaQuery.of(context);
    final size = constraints.biggest / scale;
    // Keep the same tree at 100% so zoom never remounts routes or text fields.
    return FittedBox(fit: BoxFit.fill, alignment: Alignment.topLeft,
      child: SizedBox(width: size.width, height: size.height,
        child: MediaQuery(data: media.copyWith(
          size: size, devicePixelRatio: media.devicePixelRatio * scale,
          padding: media.padding / scale, viewPadding: media.viewPadding / scale,
          viewInsets: media.viewInsets / scale, systemGestureInsets: media.systemGestureInsets / scale,
        ), child: widget.child)));
  });
}
