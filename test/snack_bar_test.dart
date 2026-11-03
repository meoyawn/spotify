import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/app/app.dart';
import 'package:spotify_flutter/app/snack_bar.dart';

double _contrast(Color foreground, Color background) =>
  (foreground.computeLuminance() + 0.05) / (background.computeLuminance() + 0.05);

void main() {
  for (final withAction in [false, true]) {
    for (final accessibleNavigation in [false, true]) {
      testWidgets('snackbar action=$withAction accessibleNavigation=$accessibleNavigation is readable and times out', (tester) async {
        tester.platformDispatcher.accessibilityFeaturesTestValue =
          FakeAccessibilityFeatures(accessibleNavigation: accessibleNavigation);
        addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
        await tester.pumpWidget(const SpotifyDesktopApp());
        await tester.pumpAndSettle();
        const message = 'This track couldn’t start playing. Try again.';
        var actions = 0;
        showSpotifySnackBar(tester.element(find.byType(Scaffold)), message,
          action: withAction ? SnackBarAction(label: 'Retry', onPressed: () => actions++) : null);
        await tester.pumpAndSettle();

        final snackBar = tester.widget<SnackBar>(find.byType(SnackBar));
        expect(snackBar.duration, const Duration(seconds: 4));
        expect(snackBar.persist, isFalse);
        final background = tester.widget<Material>(find.ancestor(
          of: find.text(message), matching: find.byType(Material)).first).color!;
        final style = DefaultTextStyle.of(tester.element(find.text(message))).style;
        expect(style.color, Colors.white);
        expect(style.fontFamily, 'SpotifyMixUI');
        expect(style.fontSize, 14);
        expect(_contrast(style.color!, background), greaterThanOrEqualTo(4.5));
        if (withAction) {
          final button = tester.widget<TextButton>(find.descendant(
            of: find.byType(SnackBarAction), matching: find.byType(TextButton)));
          final color = button.style!.foregroundColor!.resolve({})!;
          expect(_contrast(color, background), greaterThanOrEqualTo(4.5));
        }

        await tester.pump(const Duration(seconds: 3));
        expect(find.text(message), findsOneWidget);
        await tester.pump(const Duration(seconds: 1));
        await tester.pumpAndSettle();
        expect(find.byType(SnackBar), findsNothing);
        expect(actions, 0);
      });
    }
  }

  testWidgets('snackbar action runs once and dismisses immediately', (tester) async {
    await tester.pumpWidget(const SpotifyDesktopApp());
    await tester.pumpAndSettle();
    var retries = 0;
    showSpotifySnackBar(tester.element(find.byType(Scaffold)), 'Try this track again.',
      action: SnackBarAction(label: 'Retry', onPressed: () => retries++));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(retries, 1);
    expect(find.byType(SnackBar), findsNothing);
  });
}
