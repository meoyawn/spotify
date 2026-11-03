import 'dart:async';
import 'dart:math' as math;

import 'package:cancellation_token/cancellation_token.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;

import '../app/snack_bar.dart';
import 'controller.dart';
import 'repository.dart';

class LyricsView extends StatefulWidget {
  const LyricsView({super.key, required this.controller, this.preview = false, this.onExpand});
  final LyricsController controller;
  final bool preview;
  final VoidCallback? onExpand;
  @override State<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<LyricsView> {
  final _scroll = ScrollController();
  final _activeLine = GlobalKey();
  GlobalKey? _viewportKey;
  GlobalKey get _viewport => _viewportKey ??= GlobalKey();
  CancellationToken? _followCancellation;
  CancellationToken get _following => _followCancellation ??= CancellationToken();
  int _lastActive = -1;
  String? _lastUri;
  bool? _manualScroll, _showSync, _checkingScroll;

  @override void dispose() { _following.cancel(); _scroll.dispose(); super.dispose(); }

  ({double top, double height, double viewportHeight})? _linePosition() {
    final line = _activeLine.currentContext?.findRenderObject();
    final viewport = _viewport.currentContext?.findRenderObject();
    if (line is! RenderBox || viewport is! RenderBox || !line.attached || !viewport.attached) return null;
    return (top: line.localToGlobal(Offset.zero, ancestor: viewport).dy,
      height: line.size.height, viewportHeight: viewport.size.height);
  }

  void _checkSyncButton() {
    if (_checkingScroll == true || widget.preview) return;
    _checkingScroll = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkingScroll = false;
      if (!mounted) return;
      final line = _linePosition();
      final show = line != null && (line.top < 0 || line.top + line.height > line.viewportHeight);
      if (show != _showSync) setState(() => _showSync = show);
    });
  }

  Future<void> _centerLine(BuildContext context, {bool animate = true}) async {
    _following.cancel();
    final token = _followCancellation = CancellationToken();
    try {
      await Scrollable.ensureVisible(context, alignment: 0.5,
        duration: animate && !MediaQuery.disableAnimationsOf(context)
          ? const Duration(milliseconds: 250) : Duration.zero,
        curve: Curves.easeInOut).asCancellable(token, onCancel: () {
          // A user gesture has already replaced the driven scroll activity.
          if (mounted && _manualScroll != true && _scroll.hasClients) _scroll.jumpTo(_scroll.offset);
        });
    } on CancelledException { /* A new line or user scroll owns the viewport. */ }
    if (mounted) _checkSyncButton();
  }

  void _followLine(int active, bool jumped) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || active != _lastActive) return;
      final line = _linePosition(), context = _activeLine.currentContext;
      if (_manualScroll != true && line != null && context != null) {
        final fraction = 0.8 - 0.3 * ((line.viewportHeight - 400) / 200).clamp(0, 1);
        final zoneHeight = line.viewportHeight * fraction;
        final zoneTop = line.height + (line.viewportHeight - zoneHeight) / 2;
        final inZone = line.top >= zoneTop && line.top <= math.min(zoneTop + zoneHeight, line.viewportHeight);
        if (jumped || inZone) unawaited(_centerLine(context, animate: !jumped));
      }
      _checkSyncButton();
    });
  }

  bool _scrolled(ScrollNotification event) {
    if (event is ScrollStartNotification && event.dragDetails != null ||
        event is UserScrollNotification && event.direction != ScrollDirection.idle) {
      _manualScroll = true;
      _following.cancel();
    } else if (event is ScrollEndNotification) {
      _manualScroll = false;
    }
    _checkSyncButton();
    return false;
  }

  Future<void> _seek(BuildContext context, LyricsLine line) async {
    unawaited(_centerLine(context));
    try { await widget.controller.seek(line); }
    catch (_) {
      if (context.mounted) showSpotifySnackBar(context, 'Couldn’t seek to this lyric.');
    }
  }

  @override Widget build(BuildContext context) => ListenableBuilder(listenable: widget.controller,
    builder: (context, _) {
      final controller = widget.controller, lyrics = controller.lyrics;
      Widget message(String text, {bool retry = false}) => Center(child: Padding(
        padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(text, textAlign: TextAlign.center),
          if (retry) TextButton(onPressed: controller.reload, child: const Text('Try again'))])));
      if (controller.loading) return const Center(child: Padding(padding: EdgeInsets.all(24),
        child: CircularProgressIndicator()));
      if (controller.error != null) return message('Couldn’t load lyrics.', retry: true);
      if (controller.uri == null) return message('Play a song to see its lyrics.');
      if (lyrics == null || lyrics.availability == LyricsAvailability.unavailable) return message('Lyrics aren’t available for this song.');
      if (lyrics.availability == LyricsAvailability.restricted) return message('Lyrics aren’t available for this account.');
      if (widget.preview) return _LyricsPreview(lyrics: lyrics, onExpand: widget.onExpand);
      final lines = lyrics.lines;
      final position = controller.positionMs;
      final active = lyrics.isTimeSynced
        ? lines.indexWhere((line) => position >= line.startMs && (line.endMs == null || position < line.endMs!)) : -1;
      final changedTrack = _lastUri != controller.uri;
      if (active != _lastActive || changedTrack) {
        final jumped = changedTrack || _lastActive < 0 || (active - _lastActive).abs() > 4;
        if (changedTrack) { _following.cancel(); _manualScroll = false; _showSync = false; }
        _lastActive = active; _lastUri = controller.uri;
        _followLine(active, jumped);
      }
      return ColoredBox(color: Color(lyrics.background), child: LayoutBuilder(builder: (context, constraints) {
        final size = constraints.maxWidth > 1600 ? 40.0
          : constraints.maxWidth > 800 ? 32.0 : 24.0;
        final body = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (!lyrics.isTimeSynced) Padding(padding: const EdgeInsets.only(top: 62, bottom: 20),
            child: Text('These lyrics aren’t time-synced.', style: TextStyle(fontSize: 14, color: Color(lyrics.text)))),
          if (lyrics.capStatus == 'CAPPED') const Padding(padding: EdgeInsets.only(bottom: 16),
            child: Text('The lyrics limit for this account has been reached.')),
          for (final (index, line) in lines.indexed) Padding(
            key: index == active ? _activeLine : null,
            padding: EdgeInsets.only(bottom: line.words.isEmpty ? 0
              : size * (index + 1 < lines.length && lines[index + 1].words.isEmpty ? 1.4 : 0.6)),
            child: _LyricLine(words: line.words, fontSize: size,
              color: Color(!lyrics.isTimeSynced || index == active ? lyrics.highlightText : lyrics.text)
                .withValues(alpha: lyrics.isTimeSynced && active >= 0 && index < active ? 0.5 : 1),
              hoverColor: Color(lyrics.highlightText),
              onTap: controller.canSeek ? (context) => unawaited(_seek(context, line)) : null)),
          if (lyrics.providerDisplayName.isNotEmpty && lyrics.isTimeSynced)
            Padding(padding: const EdgeInsets.symmetric(vertical: 20), child: Text(
              'Lyrics provided by ' + lyrics.providerDisplayName, style: TextStyle(fontSize: 14, color: Color(lyrics.text)))),
        ]);
        return Stack(key: _viewport, fit: StackFit.expand, children: [
          NotificationListener<ScrollNotification>(onNotification: _scrolled, child: SingleChildScrollView(
            controller: _scroll, child: Align(alignment: Alignment.topCenter, child: SizedBox(
              width: math.min(math.max(0, constraints.maxWidth - 128), 1024),
              child: Padding(padding: const EdgeInsets.symmetric(vertical: 64), child: body))))),
          if (_showSync == true && active >= 0) Positioned(left: 0, right: 0, bottom: 24, child: Center(
            child: FilledButton.icon(style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.black),
              onPressed: () {
                final context = _activeLine.currentContext;
                if (context != null) { _manualScroll = false; unawaited(_centerLine(context)); }
              }, icon: const Icon(Icons.sync, size: 18), label: const Text('Sync to current line')))),
        ]);
      }));
    });
}

class _LyricsPreview extends StatelessWidget {
  const _LyricsPreview({required this.lyrics, this.onExpand});
  final TrackLyrics lyrics;
  final VoidCallback? onExpand;

  @override Widget build(BuildContext context) {
    final background = Color(lyrics.background);
    final scale = MediaQuery.textScalerOf(context).scale(1);
    return SizedBox(height: 176 * scale, child: ColoredBox(color: background,
      child: InkWell(onTap: onExpand, child: Padding(padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Lyrics preview', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 20),
          Expanded(child: ShaderMask(blendMode: BlendMode.dstIn,
            shaderCallback: (bounds) => const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter,
              colors: [Colors.white, Colors.white, Colors.transparent], stops: [0, 0.55, 1]).createShader(bounds),
            child: ClipRect(child: OverflowBox(alignment: Alignment.topLeft, minHeight: 0,
              maxHeight: double.infinity, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min, children: [
                  for (final line in lyrics.previewLines.where((line) => line.words.isNotEmpty).take(3))
                    Padding(padding: const EdgeInsets.only(bottom: 16), child: Text(line.words,
                      style: TextStyle(fontFamily: 'SpotifyMixUITitle', fontSize: 24, height: 1.2,
                        fontWeight: FontWeight.w700, color: Color(lyrics.highlightText).withValues(alpha: 0.8)))),
                ]))))),
        ])))));
  }
}

class _LyricLine extends StatefulWidget {
  const _LyricLine({required this.words, required this.fontSize, required this.color,
    required this.hoverColor, this.onTap});
  final String words;
  final double fontSize;
  final Color color, hoverColor;
  final ValueChanged<BuildContext>? onTap;
  @override State<_LyricLine> createState() => _LyricLineState();
}

class _LyricLineState extends State<_LyricLine> {
  bool _hovered = false;
  @override Widget build(BuildContext context) {
    if (widget.words.isEmpty) return const SizedBox.shrink();
    final enabled = widget.onTap != null;
    return MouseRegion(cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) { if (enabled) setState(() => _hovered = true); },
      onExit: (_) { if (_hovered) setState(() => _hovered = false); },
      child: Semantics(button: enabled, child: GestureDetector(
        onTap: enabled ? () => widget.onTap!(context) : null,
        child: Text(widget.words, style: TextStyle(fontFamily: 'SpotifyMixUITitle',
          fontSize: widget.fontSize, fontWeight: FontWeight.w700,
          color: enabled && _hovered ? widget.hoverColor : widget.color,
          decoration: enabled && _hovered ? TextDecoration.underline : TextDecoration.none)))));
  }
}
