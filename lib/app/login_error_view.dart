import 'dart:async';
import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'app_runtime.dart';
import 'desktop_host.dart';
import 'shell_icons.dart';

/// login.spa 1.3.9.2055 renderer code 408 (`accesspoint:17`) replacements.
const regionMismatchProfileUrl = 'https://www.spotify.com/redirect/account-page/';
const regionMismatchUpgradeUrl = 'https://www.spotify.com/redirect/upgrade-product/';

/// The original login view after an AP login rejection: its negative error
/// banner above the browser log-in card, modal over the signed-out shell.
class DesktopLoginErrorOverlay extends StatelessWidget {
  const DesktopLoginErrorOverlay({super.key, required this.error, required this.onDismiss,
    required this.onLogIn, this.onOpenSettings, this.openUrl});
  final SpotifyLoginError error;
  final VoidCallback onDismiss, onLogIn;
  final VoidCallback? onOpenSettings;
  final ValueChanged<String>? openUrl;

  @override
  Widget build(BuildContext context) => Material(type: MaterialType.transparency, child: BackdropFilter(
    filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
    child: ColoredBox(color: const Color(0xb3000000), child: Center(child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ConstrainedBox(constraints: const BoxConstraints(maxWidth: 416),
          child: _RegionMismatchBanner(error: error, onDismiss: onDismiss,
            openUrl: openUrl ?? (url) => unawaited(const DesktopHost().openExternalUrl(url)))),
        const SizedBox(height: 18),
        _LogInCard(onLogIn: onLogIn, onOpenSettings: onOpenSettings),
      ]))))));
}

class _RegionMismatchBanner extends StatefulWidget {
  const _RegionMismatchBanner({required this.error, required this.onDismiss, required this.openUrl});
  final SpotifyLoginError error;
  final VoidCallback onDismiss;
  final ValueChanged<String> openUrl;
  @override State<_RegionMismatchBanner> createState() => _RegionMismatchBannerState();
}

class _RegionMismatchBannerState extends State<_RegionMismatchBanner> {
  late final _profile = TapGestureRecognizer()..onTap = () => widget.openUrl(regionMismatchProfileUrl);
  late final _upgrade = TapGestureRecognizer()..onTap = () => widget.openUrl(regionMismatchUpgradeUrl);

  @override
  void dispose() { _profile.dispose(); _upgrade.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(color: Colors.white, fontSize: 14, height: 1.45);
    return Semantics(liveRegion: true, child: DecoratedBox(
      decoration: BoxDecoration(color: const Color(0xffe91429), borderRadius: BorderRadius.circular(4)),
      child: Padding(padding: const EdgeInsets.fromLTRB(16, 12, 8, 12), child: Row(children: [
        const Icon(Icons.error_outline, color: Colors.white, size: 20),
        const SizedBox(width: 12),
        Expanded(child: Text.rich(TextSpan(style: style, children: [
          const TextSpan(text: 'Your country does not match the one set in your profile. To continue use, '),
          TextSpan(text: 'update your profile', recognizer: _profile, mouseCursor: SystemMouseCursors.click),
          const TextSpan(text: ' or '),
          TextSpan(text: 'upgrade your Spotify account', recognizer: _upgrade, mouseCursor: SystemMouseCursors.click),
          TextSpan(text: '.\n(Error code: ${widget.error.reference})'),
        ]))),
        IconButton(onPressed: widget.onDismiss,
          icon: const Icon(SpotifyShellIcons.close, color: Colors.white, size: 16, semanticLabel: 'Close')),
      ]))));
  }
}

class _LogInCard extends StatelessWidget {
  const _LogInCard({required this.onLogIn, this.onOpenSettings});
  final VoidCallback onLogIn;
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context) => Container(width: 416,
    padding: const EdgeInsets.fromLTRB(32, 32, 32, 24),
    decoration: BoxDecoration(color: const Color(0xff121212), borderRadius: BorderRadius.circular(8)),
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(SpotifyShellIcons.brand, color: Colors.white, size: 40),
        SizedBox(width: 6),
        Text('Spotify', style: TextStyle(fontFamily: 'SpotifyMixUITitle', color: Colors.white,
          fontSize: 28, fontWeight: FontWeight.w700, letterSpacing: -.5)),
      ]),
      const SizedBox(height: 32),
      const Text('Millions of songs.\nFree on Spotify.', textAlign: TextAlign.center,
        style: TextStyle(fontFamily: 'SpotifyMixUITitle', color: Colors.white, fontSize: 24,
          fontWeight: FontWeight.w700, height: 1.3)),
      const SizedBox(height: 28),
      FilledButton(onPressed: onLogIn,
        style: FilledButton.styleFrom(backgroundColor: const Color(0xff1ed760),
          foregroundColor: Colors.black, minimumSize: const Size(144, 52),
          padding: const EdgeInsets.symmetric(horizontal: 32), shape: const StadiumBorder()),
        child: const Row(mainAxisSize: MainAxisSize.min, children: [
          Text('Log in', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          SizedBox(width: 8),
          Icon(Icons.open_in_new, size: 20),
        ])),
      if (onOpenSettings != null) ...[
        const SizedBox(height: 24),
        TextButton(onPressed: onOpenSettings,
          style: TextButton.styleFrom(foregroundColor: const Color(0xffb3b3b3)),
          child: const Text('Settings', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700))),
      ],
    ]));
}
