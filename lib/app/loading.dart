import 'dart:async';

import 'package:flutter/material.dart';

/// Original renderer modules 12414 / 67707 and xpui-snapshot.css.
class SpotifyLoadingPage extends StatelessWidget {
  const SpotifyLoadingPage({super.key});

  @override
  Widget build(BuildContext context) => Stack(children: [
    Positioned(top: -64, left: 0, right: 0,
      height: (MediaQuery.sizeOf(context).height - 96).clamp(0, double.infinity),
      child: const Center(child: SpotifyLoadingIndicator())),
  ]);
}

class SpotifyLoadingIndicator extends StatefulWidget {
  const SpotifyLoadingIndicator({super.key});

  @override
  State<SpotifyLoadingIndicator> createState() => _SpotifyLoadingIndicatorState();
}

class _SpotifyLoadingIndicatorState extends State<SpotifyLoadingIndicator>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final _animation = AnimationController(vsync: this,
    duration: const Duration(milliseconds: 1320));
  Timer? _delay;
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _delay = Timer(const Duration(seconds: 1), () {
      setState(() => _visible = true);
      _syncAnimation();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncAnimation();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _syncAnimation();

  void _syncAnimation() {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    final animate = _visible && !MediaQuery.disableAnimationsOf(context) &&
      TickerMode.valuesOf(context).enabled && (lifecycle == null || lifecycle == AppLifecycleState.resumed);
    if (animate) {
      if (!_animation.isAnimating) _animation.repeat();
    } else {
      _animation.stop();
    }
  }

  @override
  void dispose() {
    _delay?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(label: 'Loading',
    child: SizedBox(width: 56, height: 12, child: _visible
      ? RepaintBoundary(child: CustomPaint(painter: _LoadingDots(_animation,
          reducedMotion: MediaQuery.disableAnimationsOf(context))))
      : null));
}

class _LoadingDots extends CustomPainter {
  _LoadingDots(this.animation, {required this.reducedMotion}) : super(repaint: animation);
  final AnimationController animation;
  final bool reducedMotion;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    final elapsed = (animation.lastElapsedDuration?.inMicroseconds ?? 0) / 1000;
    for (var index = 0; index < 3; index++) {
      final phase = (animation.value - index * 100 / 1320) % 1;
      final waiting = !reducedMotion && elapsed < index * 100 && animation.value < index * 100 / 1320;
      final pulse = reducedMotion ? 0.0 : phase < .4
        ? const Cubic(1, 0, .7, 1).transform(phase / .4)
        : phase < .725 ? 1 - const Cubic(.3, 0, 0, 1).transform((phase - .4) / .325) : 0.0;
      final scale = 1 + .3 * pulse;
      paint.color = Colors.white.withValues(alpha: waiting ? 1 : .5 + .25 * pulse);
      canvas.drawCircle(Offset(size.width / 2 + ((index - 1) * 140 - .5) * .12 * scale,
        size.height / 2), 32 * .12 * scale, paint);
    }
  }

  @override
  bool shouldRepaint(_LoadingDots oldDelegate) =>
    oldDelegate.animation != animation || oldDelegate.reducedMotion != reducedMotion;
}
