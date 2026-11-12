import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spotify_flutter/app/app.dart';

Rect _paintedRect(WidgetTester tester, Finder finder) =>
  Rect.fromPoints(tester.getTopLeft(finder), tester.getBottomRight(finder));

Future<void> _command(WidgetTester tester, LogicalKeyboardKey key, {bool shift = false}) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(key);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> openApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const SpotifyDesktopApp());
    await tester.pumpAndSettle();
  }

  testWidgets('command zoom relayouts the whole app and dialogs without losing input or hit targets', (tester) async {
    await openApp(tester);
    final home = find.byTooltip('Home');
    final normal = _paintedRect(tester, home).size;
    final input = find.byType(TextField);
    await tester.enterText(input, 'Keep this search');
    final editable = tester.widget<EditableText>(find.byType(EditableText));

    await _command(tester, LogicalKeyboardKey.equal, shift: true);
    expect(_paintedRect(tester, home).width, closeTo(normal.width * 1.1, .001));
    expect(_paintedRect(tester, home).height, closeTo(normal.height * 1.1, .001));
    expect(MediaQuery.sizeOf(tester.element(input)).width, closeTo(1600 / 1.1, .001));
    expect(editable.focusNode.hasFocus, isTrue);
    expect(tester.widget<EditableText>(find.byType(EditableText)).controller.text, 'Keep this search');

    await tester.tap(find.text('Log in'));
    await tester.pumpAndSettle();
    final dialog = find.byType(AlertDialog);
    expect(dialog, findsOneWidget);
    expect(MediaQuery.sizeOf(tester.element(dialog)).width, closeTo(1600 / 1.1, .001));
    await _command(tester, LogicalKeyboardKey.minus);
    await _command(tester, LogicalKeyboardKey.minus);
    expect(MediaQuery.sizeOf(tester.element(dialog)).width, closeTo(1600 / .9, .001));
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(dialog, findsNothing);

    await _command(tester, LogicalKeyboardKey.digit0);
    expect(_paintedRect(tester, home).size, normal);
    expect(tester.takeException(), isNull);
  }, semanticsEnabled: false);

  testWidgets('zoom is bounded, saved and restored across app launches', (tester) async {
    SharedPreferences.setMockInitialValues({'ui.scale': 1.25});
    await openApp(tester);
    final home = find.byTooltip('Home');
    expect(_paintedRect(tester, home).width, closeTo(48 * 1.25, .001));
    for (var index = 0; index < 16; index++) {
      await _command(tester, LogicalKeyboardKey.minus);
    }
    expect(_paintedRect(tester, home).width, closeTo(48 * .5, .001));
    expect(_paintedRect(tester, find.byTooltip('Go back')).left, greaterThanOrEqualTo(80));
    final library = find.byKey(const ValueKey('library-panel'));
    final width = _paintedRect(tester, library).width;
    await tester.drag(find.byKey(const ValueKey('library-resize')), const Offset(30, 0));
    await tester.pumpAndSettle();
    expect(_paintedRect(tester, library).width, closeTo(width + 30, .5));
    for (var index = 0; index < 16; index++) {
      await _command(tester, LogicalKeyboardKey.equal);
    }
    expect(_paintedRect(tester, home).width, closeTo(48 * 2, .001));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SpotifyDesktopApp());
    await tester.pumpAndSettle();
    expect(_paintedRect(tester, home).width, closeTo(48 * 2, .001));
    await _command(tester, LogicalKeyboardKey.digit0);
    expect(_paintedRect(tester, home).width, closeTo(48, .001));
    expect(tester.takeException(), isNull);
  }, semanticsEnabled: false, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}
