import 'dart:async';

import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show GestureBinding, TapGestureRecognizer, PointerScrollEvent;
import 'package:flutter/services.dart' show HardwareKeyboard, KeyEvent, KeyUpEvent, LogicalKeyboardKey;

import '../entities/models.dart';
import '../playback/controller.dart';
import '../playback/models.dart';
import '../playback/requests.dart';
import 'shell_icons.dart';
import 'snack_bar.dart';
import 'share_links.dart';

typedef DesktopPlaybackBuilder = Widget Function(
  BuildContext context,
  PlaybackController? controller,
  PlaybackState? state,
);
typedef PlaybackArtworkBuilder = Widget Function(BuildContext context, PlaybackItem item);
typedef TrackSaveButtonBuilder = Widget Function(BuildContext context, String trackUri);

/// Renders reported player state; ownership of subscriptions stays with caller.
class DesktopPlaybackBar extends StatefulWidget {
  const DesktopPlaybackBar({super.key, this.controller, this.builder,
    this.lyricsActive = false,
    this.onShowLyrics, this.onNavigate, this.onToggleMute,
    this.onVolumeChanged, this.volume = 1, this.artworkBuilder, this.trackSaveButtonBuilder});

  final PlaybackController? controller;
  final VoidCallback? onShowLyrics;
  final bool lyricsActive;
  final VoidCallback? onToggleMute;
  final ValueChanged<EntityLink>? onNavigate;
  final DesktopPlaybackBuilder? builder;
  final ValueChanged<double>? onVolumeChanged;
  final double volume;
  final PlaybackArtworkBuilder? artworkBuilder;
  final TrackSaveButtonBuilder? trackSaveButtonBuilder;

  @override
  State<DesktopPlaybackBar> createState() => _DesktopPlaybackBarState();
}

class _DesktopPlaybackBarState extends State<DesktopPlaybackBar> {
  Stream<PlaybackState>? _controls;

  @override
  void initState() {
    super.initState();
    _controls = widget.controller?.states.distinct(_sameControls);
  }

  @override
  void didUpdateWidget(DesktopPlaybackBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _controls = widget.controller?.states.distinct(_sameControls);
    }
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<PlaybackState>(
    key: ObjectKey(widget.controller),
    stream: _controls,
    initialData: widget.controller?.state,
    builder: (context, snapshot) {
      final state = snapshot.data?.isAdvertising == true ? null : snapshot.data;
      final custom = widget.builder;
      if (custom != null) return custom(context, widget.controller, state);
      return _PlayerContents(controller: widget.controller, state: state,
        lyricsActive: widget.lyricsActive,
        onShowLyrics: widget.onShowLyrics,
        onNavigate: widget.onNavigate, onToggleMute: widget.onToggleMute,
        onVolumeChanged: widget.onVolumeChanged, volume: widget.volume, artworkBuilder: widget.artworkBuilder,
        trackSaveButtonBuilder: widget.trackSaveButtonBuilder);
    },
  );
}

// Position events belong to the progress row, not artwork, links and transport.
bool _sameControls(PlaybackState a, PlaybackState b) {
  final first = a.item, second = b.item;
  final ar = a.restrictions, br = b.restrictions;
  return a.hasContext == b.hasContext && a.isPaused == b.isPaused &&
    a.isBuffering == b.isBuffering && a.isAdvertising == b.isAdvertising &&
    a.playbackId == b.playbackId && a.durationMs == b.durationMs &&
    a.shuffle == b.shuffle && a.repeat == b.repeat &&
    first?.uri == second?.uri && first?.name == second?.name &&
    mapEquals(first?.metadata, second?.metadata) &&
    ar.canPause == br.canPause && ar.canResume == br.canResume && ar.canSeek == br.canSeek &&
    ar.canSkipPrevious == br.canSkipPrevious && ar.canSkipNext == br.canSkipNext &&
    ar.canToggleShuffle == br.canToggleShuffle &&
    ar.canToggleRepeatContext == br.canToggleRepeatContext && ar.canToggleRepeatTrack == br.canToggleRepeatTrack;
}

class _PlayerContents extends StatelessWidget {
  const _PlayerContents({required this.controller, required this.state,
    this.lyricsActive = false,
    this.onShowLyrics, this.onNavigate, this.onToggleMute,
    required this.onVolumeChanged, required this.volume, this.artworkBuilder,
    this.trackSaveButtonBuilder});

  final PlaybackController? controller;
  final VoidCallback? onShowLyrics;
  final bool lyricsActive;
  final VoidCallback? onToggleMute;
  final ValueChanged<EntityLink>? onNavigate;
  final PlaybackState? state;
  final ValueChanged<double>? onVolumeChanged;
  final double volume;
  final PlaybackArtworkBuilder? artworkBuilder;
  final TrackSaveButtonBuilder? trackSaveButtonBuilder;

  void _command(BuildContext context, Future<void> Function() command) {
    unawaited(Future<void>.sync(command).catchError((Object error) {
      if (!context.mounted) return;
      showSpotifySnackBar(context, 'Playback is currently unavailable.');
    }));
  }

  @override
  Widget build(BuildContext context) {
    Widget? contents;
    int? contentsBand;
    return LayoutBuilder(builder: (context, constraints) {
    final band = constraints.maxWidth < 480 ? 0 : constraints.maxWidth < 600 ? 1
      : constraints.maxWidth < 960 ? 2 : 3;
    if (contents != null && contentsBand == band) return contents!;
    contentsBand = band;
    final current = state;
    final player = controller;
    final hasState = current != null && player != null &&
        (current.hasContext || (current.item != null && !current.isBuffering));
    final canToggle = hasState && (current.isPaused
        ? current.restrictions.canResume : current.restrictions.canPause);
    final metadata = current?.item;
    final trackUri = metadata?.metadata['original_uri'] ?? metadata?.uri;
    final saveButton = trackUri != null && RegExp(r'^spotify:track:[0-9A-Za-z]{22}$').hasMatch(trackUri)
      ? trackSaveButtonBuilder?.call(context, trackUri) : null;
    final repeat = current?.repeat ?? PlaybackRepeat.none;
    final nextRepeat = _nextRepeat(repeat, current?.restrictions.canToggleRepeatContext ?? false,
      current?.restrictions.canToggleRepeatTrack ?? false);
    final play = Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      if (constraints.maxWidth >= 480) ...[
        _ModeButton(tooltip: current?.shuffle == true ? 'Disable shuffle' : 'Enable shuffle',
          icon: SpotifyShellIcons.shuffle, active: current?.shuffle == true,
          onPressed: hasState && current.restrictions.canToggleShuffle
            ? () => _command(context, () => player.setShuffle(current.shuffle != true)) : null),
        const SizedBox(width: 8),
      ],
      _PlayerControl(
        tooltip: 'Previous',
        debounce: true,
        onPressed: hasState && (current.restrictions.canSkipPrevious || current.restrictions.canSeek)
            ? () => _command(context, player.skipPrevious) : null,
        icon: const Icon(SpotifyShellIcons.previous, size: 16),
      ),
      const SizedBox(width: 16),
      SizedBox(width: 32, height: 32, child: _PlayerControl(
        tooltip: current != null && !current.isPaused ? 'Pause' : 'Play',
        debounce: true,
        backgroundColor: canToggle ? Colors.white : const Color(0xffb3b3b3),
        color: Colors.black, disabledColor: const Color(0xff121212),
        onPressed: canToggle ? () => _command(context, () => current.isPaused
          ? player.resume(const PlaybackOrigin(featureIdentifier: 'npb'))
          : player.pause(const PlaybackOrigin(featureIdentifier: 'npb'))) : null,
        icon: Icon(current != null && !current.isPaused
            ? SpotifyShellIcons.pause : SpotifyShellIcons.play, size: 16),
      )),
      const SizedBox(width: 16),
      _PlayerControl(
        tooltip: 'Next',
        debounce: true,
        onPressed: hasState && current.restrictions.canSkipNext
            ? () => _command(context, player.skipNext) : null,
        icon: const Icon(SpotifyShellIcons.next, size: 16),
      ),
      if (constraints.maxWidth >= 480) ...[
        const SizedBox(width: 8),
        _ModeButton(tooltip: switch (nextRepeat) {
          PlaybackRepeat.none => 'Disable repeat', PlaybackRepeat.context => 'Enable repeat',
          PlaybackRepeat.track => 'Enable repeat one',
        }, icon: repeat == PlaybackRepeat.track ? SpotifyShellIcons.repeatOne : SpotifyShellIcons.repeat,
          active: repeat != PlaybackRepeat.none,
          onPressed: hasState && (current.restrictions.canToggleRepeatContext || current.restrictions.canToggleRepeatTrack)
            ? () => _command(context, () => player.setRepeat(nextRepeat)) : null),
      ],
    ]);
    final progress = _PlaybackProgress(controller: player,
      onSeek: hasState && current.restrictions.canSeek
        ? (value) => _command(context, () => player.seekTo(value)) : null);
    final middle = Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      play,
      if (constraints.maxWidth >= 480) ...[const SizedBox(height: 8), progress],
    ]);
    return contents = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(children: [
        if (constraints.maxWidth >= 600) Expanded(flex: 3, child: SpotifyLinkContextMenu(uri: trackUri ?? '', child: Padding(
          padding: const EdgeInsets.only(right: 16),
          child: Row(children: [
            if (metadata != null) ...[SizedBox.square(dimension: 56,
              child: artworkBuilder?.call(context, metadata) ?? const ColoredBox(color: Color(0xff282828))),
              const SizedBox(width: 16)],
            Flexible(child: Column(mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start, children: [
                _PlayerTextLink(text: metadata?.name ?? '',
                  link: metadata?.metadata['is_local'] == 'true' ? null : EntityLink.fromJson({
                    'uri': metadata?.metadata['album_uri'], 'name': metadata?.metadata['album_title'],
                  }, type: 'album'), onNavigate: onNavigate),
                if (metadata?.metadata['artist_name']?.isNotEmpty == true) ...[
                  const SizedBox(height: 2), _PlayerArtistLinks(item: metadata!,
                    onNavigate: metadata.metadata['is_local'] == 'true' ? null : onNavigate)],
              ])),
            if (saveButton != null) ...[const SizedBox(width: 8), saveButton],
          ]),
        ))),
        Expanded(flex: constraints.maxWidth >= 600 ? 4 : 1,
          child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 722), child: middle))),
        if (constraints.maxWidth >= 600) Expanded(flex: 3, child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            _PlayerControl(tooltip: 'Lyrics', onPressed: metadata?.type == 'track' ? onShowLyrics : null,
              active: lyricsActive,
              icon: const Icon(Icons.lyrics_outlined, size: 18)),
            if (constraints.maxWidth >= 960) const _PlayerControl(tooltip: 'Queue', onPressed: null,
              icon: Icon(SpotifyShellIcons.queue, size: 16)),
            if (constraints.maxWidth >= 960) const _PlayerControl(tooltip: 'Connect to a device', onPressed: null,
              icon: Icon(SpotifyShellIcons.devices, size: 16)),
            _VolumeControl(volume: volume, onChanged: onVolumeChanged, onToggleMute: onToggleMute,
              width: constraints.maxWidth >= 960 ? 93 : 72),
          ],
        )),
      ]),
    );
  });
  }
}

PlaybackRepeat _nextRepeat(PlaybackRepeat current, bool canContext, bool canTrack) {
  final value = current.index;
  return PlaybackRepeat.values[canContext && canTrack ? (value + 1) % 3
    : canContext ? (value + 1) % 2 : canTrack ? value == 1 ? 2 : (value + 2) % 4 : 0];
}

class _ModeButton extends StatelessWidget {
  const _ModeButton({required this.tooltip, required this.icon, required this.active, this.onPressed});
  final String tooltip;
  final IconData icon;
  final bool active;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => _PlayerControl(tooltip: tooltip,
    active: active, debounce: true, onPressed: onPressed, icon: Icon(icon, size: 16));
}

class _PlayerControl extends StatefulWidget {
  const _PlayerControl({required this.tooltip, required this.icon, this.onPressed,
    this.active, this.backgroundColor, this.debounce = false, this.color = const Color(0xffb3b3b3),
    this.disabledColor = const Color(0xff4d4d4d)});
  final String tooltip;
  final Widget icon;
  final VoidCallback? onPressed;
  final bool? active;
  final bool debounce;
  final Color? backgroundColor;
  final Color color, disabledColor;

  @override
  State<_PlayerControl> createState() => _PlayerControlState();
}

class _PlayerControlState extends State<_PlayerControl> {
  bool _hovered = false, _focused = false;
  int? _lastActivation;

  void _activate() {
    if (widget.onPressed == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (widget.debounce && _lastActivation != null && now - _lastActivation! < 100) return;
    _lastActivation = now;
    widget.onPressed!();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final active = widget.active == true;
    final color = !enabled ? widget.disabledColor : active
      ? _hovered || _focused ? const Color(0xff1ed760) : const Color(0xff1db954)
      : widget.backgroundColor != null ? widget.color : _hovered || _focused ? Colors.white : widget.color;
    return Tooltip(message: widget.tooltip, excludeFromSemantics: true,
      child: Semantics(button: true, enabled: enabled, toggled: widget.active, label: widget.tooltip,
        child: FocusableActionDetector(enabled: enabled,
          mouseCursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
          onShowHoverHighlight: (value) => setState(() => _hovered = value),
          onShowFocusHighlight: (value) => setState(() => _focused = value),
          actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
            _activate();
            return null;
          })},
          child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: enabled ? _activate : null,
            child: SizedBox.square(dimension: 32, child: Stack(alignment: Alignment.center, children: [
              Transform.scale(scale: enabled && _hovered && widget.backgroundColor != null ? 1.06 : 1,
                child: Container(width: 32, height: 32, alignment: Alignment.center,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: widget.backgroundColor,
                    border: _focused ? Border.all(color: Colors.white) : null),
                  child: IconTheme.merge(data: IconThemeData(color: color), child: widget.icon))),
              if (active) Positioned(bottom: 0, child: Container(width: 4, height: 4,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle))),
            ]))))));
  }
}

class _PlayerTextLink extends StatefulWidget {
  const _PlayerTextLink({required this.text, this.link, this.onNavigate});
  final String text;
  final EntityLink? link;
  final ValueChanged<EntityLink>? onNavigate;

  @override
  State<_PlayerTextLink> createState() => _PlayerTextLinkState();
}

class _PlayerTextLinkState extends State<_PlayerTextLink> {
  bool _hovered = false, _focused = false;

  @override
  Widget build(BuildContext context) {
    final link = widget.link;
    final enabled = link != null && widget.onNavigate != null;
    void navigate() { if (enabled) widget.onNavigate!(link); }
    return Semantics(link: enabled, child: FocusableActionDetector(enabled: enabled,
      mouseCursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onShowHoverHighlight: (value) => setState(() => _hovered = value),
      onShowFocusHighlight: (value) => setState(() => _focused = value),
      actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) { navigate(); return null; })},
      child: GestureDetector(onTap: enabled ? navigate : null, child: Text(widget.text,
        maxLines: 1, overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 14, color: Colors.white,
          decoration: enabled && (_hovered || _focused) ? TextDecoration.underline : null)))));
  }
}

class _PlayerArtistLinks extends StatefulWidget {
  const _PlayerArtistLinks({required this.item, this.onNavigate});
  final PlaybackItem item;
  final ValueChanged<EntityLink>? onNavigate;

  @override
  State<_PlayerArtistLinks> createState() => _PlayerArtistLinksState();
}

class _PlayerArtistLinksState extends State<_PlayerArtistLinks> {
  final _recognizers = <int, TapGestureRecognizer>{};
  int? _hovered;

  @override
  void dispose() {
    for (final recognizer in _recognizers.values) { recognizer.dispose(); }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final artists = (widget.item.toJson()['artists'] as List? ?? []).cast<PlaybackJson>()
      .where((artist) => (artist['name'] as String? ?? '').isNotEmpty).toList(growable: false);
    return Text.rich(TextSpan(children: [for (final (index, artist) in artists.indexed) ...[
      if (index != 0) const TextSpan(text: ', '),
      _artist(artist, index),
    ]]), maxLines: 1, overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontSize: 12, height: 1.2, color: Color(0xffb3b3b3)));
  }

  TextSpan _artist(PlaybackJson artist, int index) {
    final link = EntityLink.fromJson(artist, type: 'artist');
    final enabled = link != null && widget.onNavigate != null;
    final recognizer = _recognizers.putIfAbsent(index, () => TapGestureRecognizer());
    recognizer.onTap = enabled ? () => widget.onNavigate!(link) : null;
    final shareable = spotifyShareLink(link?.uri ?? '') != null;
    recognizer.onSecondaryTapUp = shareable
      ? (details) => unawaited(showSpotifyLinkContextMenu(context, link!.uri, details.globalPosition)) : null;
    return TextSpan(text: artist['name'] as String, recognizer: enabled || shareable ? recognizer : null,
      mouseCursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: enabled ? (_) => setState(() => _hovered = index) : null,
      onExit: enabled ? (_) => setState(() => _hovered = null) : null,
      style: enabled && _hovered == index
        ? const TextStyle(color: Colors.white, decoration: TextDecoration.underline) : null);
  }
}

class _PlaybackProgress extends StatelessWidget {
  const _PlaybackProgress({required this.controller, this.onSeek});
  final PlaybackController? controller;
  final ValueChanged<int>? onSeek;

  @override
  Widget build(BuildContext context) => StreamBuilder<PlaybackState>(
    key: ObjectKey(controller), stream: controller?.states, initialData: controller?.state,
    builder: (context, snapshot) {
      final state = snapshot.data?.isAdvertising == true ? null : snapshot.data;
      final position = state?.positionAsOfTimestamp, duration = state?.durationMs;
      return Row(children: [
        SizedBox(width: 38, child: Text(position == null ? '' : _time(position),
          textAlign: TextAlign.end, style: const TextStyle(fontSize: 12, color: Color(0xffb3b3b3)))),
        const SizedBox(width: 8),
        Expanded(child: _PlaybackSeekControl(key: ValueKey(state?.playbackId ?? state?.item?.uri),
          position: position ?? 0, duration: duration ?? 0,
          keyboardStep: state?.item?.type == 'track' ? 5000 : 15000, onSeek: onSeek)),
        const SizedBox(width: 8),
        SizedBox(width: 38, child: Text(duration == null ? '' : _time(duration),
          style: const TextStyle(fontSize: 12, color: Color(0xffb3b3b3)))),
      ]);
    });
}

class _VolumeControl extends StatefulWidget {
  const _VolumeControl({required this.volume, required this.width, this.onChanged, this.onToggleMute});
  final double volume, width;
  final ValueChanged<double>? onChanged;
  final VoidCallback? onToggleMute;

  @override
  State<_VolumeControl> createState() => _VolumeControlState();
}

class _VolumeControlState extends State<_VolumeControl> {
  bool _hovered = false;
  double? _drag, _pending;
  Timer? _throttle;

  void _change(double value) {
    setState(() => _drag = value);
    if (_throttle == null) {
      widget.onChanged?.call(value);
      _throttle = Timer(const Duration(milliseconds: 25), _flush);
    } else { _pending = value; }
  }

  void _flush() {
    _throttle = null;
    final pending = _pending;
    _pending = null;
    if (pending != null) widget.onChanged?.call(pending);
  }

  @override
  void dispose() { _throttle?.cancel(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final volume = (_drag ?? widget.volume).clamp(0.0, 1.0);
    final icon = volume == 0 ? SpotifyShellIcons.volumeOff : volume < 1 / 3
      ? SpotifyShellIcons.volumeLow : volume < 2 / 3 ? SpotifyShellIcons.volumeMedium : SpotifyShellIcons.volume;
    return MouseRegion(onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Listener(onPointerSignal: (event) {
        if (event is! PointerScrollEvent || widget.onChanged == null) return;
        GestureBinding.instance.pointerSignalResolver.register(event, (event) {
          final delta = (event as PointerScrollEvent).scrollDelta;
          final amount = delta.dy.abs() >= delta.dx.abs() ? delta.dy : delta.dx;
          widget.onChanged!((widget.volume - amount.clamp(-120.0, 120.0) / 1200).clamp(0.0, 1.0));
        });
      }, child: Row(mainAxisSize: MainAxisSize.min, children: [
        _PlayerControl(tooltip: volume == 0 ? 'Unmute' : 'Mute', onPressed: widget.onToggleMute,
          icon: Icon(icon, size: 16)),
        SizedBox(width: widget.width, child: _PlaybackSlider(value: volume, max: 1, label: 'Volume', keyboardStep: 0.1,
          forceActive: _hovered || _drag != null, onChanged: widget.onChanged == null ? null : _change,
          onEnd: widget.onChanged == null ? null : (value) {
            _throttle?.cancel(); _throttle = null; _pending = null;
            widget.onChanged!(value);
            setState(() => _drag = null);
          })),
      ])));
  }
}

class _PlaybackSlider extends StatefulWidget {
  const _PlaybackSlider({required this.value, required this.max, required this.label, required this.keyboardStep,
    this.onChanged, this.onEnd, this.forceActive = false});
  final double value, max, keyboardStep;
  final String label;
  final ValueChanged<double>? onChanged, onEnd;
  final bool forceActive;

  @override
  State<_PlaybackSlider> createState() => _PlaybackSliderState();
}

class _PlaybackSliderState extends State<_PlaybackSlider> {
  bool _hovered = false, _focused = false;
  final _focus = FocusNode();
  double? _keyboardValue;
  Timer? _keyboardCommit;

  void _commitKeyboard() {
    _keyboardCommit?.cancel(); _keyboardCommit = null;
    final value = _keyboardValue;
    _keyboardValue = null;
    if (value != null) widget.onEnd?.call(value);
  }

  void _step(double offset) {
    final value = ((_keyboardValue ?? widget.value) + offset).clamp(0.0, widget.max);
    _keyboardValue = value;
    widget.onChanged?.call(value);
    _keyboardCommit ??= Timer(const Duration(milliseconds: 500), _commitKeyboard);
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (widget.onChanged == null) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isMetaPressed || keyboard.isControlPressed || keyboard.isAltPressed) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final offset = key == LogicalKeyboardKey.arrowRight || key == LogicalKeyboardKey.arrowUp ? widget.keyboardStep
      : key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.arrowDown ? -widget.keyboardStep : null;
    final digit = RegExp(r'^[0-9]$').hasMatch(key.keyLabel) ? int.tryParse(key.keyLabel) : null;
    if (offset == null && digit == null && key != LogicalKeyboardKey.home && key != LogicalKeyboardKey.end) {
      return KeyEventResult.ignored;
    }
    if (event is! KeyUpEvent) {
      if (offset != null) { _step(offset); }
      else {
        _keyboardValue = digit != null ? widget.max * digit / 10 : key == LogicalKeyboardKey.home ? 0 : widget.max;
        widget.onChanged!(_keyboardValue!);
        _commitKeyboard();
      }
    }
    return KeyEventResult.handled;
  }

  @override
  void dispose() { _keyboardCommit?.cancel(); _focus.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final active = widget.onChanged != null && (_hovered || _focused || widget.forceActive);
    return MouseRegion(onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Focus(focusNode: _focus, canRequestFocus: widget.onChanged != null,
        descendantsAreFocusable: false, onKeyEvent: _key,
        onFocusChange: (value) => setState(() => _focused = value),
        child: SliderTheme(data: SliderTheme.of(context).copyWith(trackHeight: 4, trackGap: 0,
          trackShape: const _PlayerTrackShape(),
          activeTrackColor: active ? const Color(0xff1db954) : Colors.white,
          inactiveTrackColor: const Color(0xff4d4d4d), thumbColor: Colors.white,
          disabledActiveTrackColor: const Color(0xffb3b3b3), disabledInactiveTrackColor: const Color(0xff4d4d4d),
          thumbShape: RoundSliderThumbShape(enabledThumbRadius: active ? 6 : 0, disabledThumbRadius: 0),
          overlayShape: SliderComponentShape.noOverlay, showValueIndicator: ShowValueIndicator.never),
          child: SizedBox(height: 12, child: Semantics(label: widget.label, excludeSemantics: true,
            value: widget.max == 1 ? '${(widget.value * 100).round()}%' : _time(widget.value.round()),
            onIncrease: widget.onChanged == null ? null : () => _step(widget.keyboardStep),
            onDecrease: widget.onChanged == null ? null : () => _step(-widget.keyboardStep),
            child: Listener(onPointerDown: (_) {
              if (widget.onChanged == null) return;
              _keyboardCommit?.cancel(); _keyboardCommit = null; _keyboardValue = null;
              _focus.requestFocus();
            }, child: Slider(value: widget.value, max: widget.max, padding: EdgeInsets.zero,
              onChanged: widget.onChanged, onChangeEnd: widget.onEnd)))))));
  }
}

class _PlayerTrackShape extends RoundedRectSliderTrackShape {
  const _PlayerTrackShape();

  @override
  void paint(PaintingContext context, Offset offset, {required RenderBox parentBox,
    required SliderThemeData sliderTheme, required Animation<double> enableAnimation,
    required TextDirection textDirection, required Offset thumbCenter, Offset? secondaryOffset,
    bool isDiscrete = false, bool isEnabled = false, double additionalActiveTrackHeight = 0}) {
    super.paint(context, offset, parentBox: parentBox, sliderTheme: sliderTheme,
      enableAnimation: enableAnimation, textDirection: textDirection, thumbCenter: thumbCenter,
      secondaryOffset: secondaryOffset, isDiscrete: isDiscrete, isEnabled: isEnabled,
      additionalActiveTrackHeight: 0);
  }
}

class _PlaybackSeekControl extends StatefulWidget {
  const _PlaybackSeekControl({super.key, required this.position, required this.duration,
    required this.keyboardStep, this.onSeek});
  final int position, duration;
  final double keyboardStep;
  final ValueChanged<int>? onSeek;

  @override
  State<_PlaybackSeekControl> createState() => _PlaybackSeekControlState();
}

class _PlaybackSeekControlState extends State<_PlaybackSeekControl> {
  double? _drag;
  @override
  Widget build(BuildContext context) {
    final duration = widget.duration.toDouble();
    return _PlaybackSlider(value: (_drag ?? widget.position.toDouble()).clamp(0, duration > 0 ? duration : 1),
        max: duration > 0 ? duration : 1,
        keyboardStep: widget.keyboardStep,
        label: 'Playback position', forceActive: _drag != null,
        onChanged: widget.onSeek == null || duration <= 0 ? null : (value) => setState(() => _drag = value),
        onEnd: widget.onSeek == null || duration <= 0 ? null : (value) {
          setState(() => _drag = null);
          widget.onSeek!(value.round());
        });
  }
}

String _time(int milliseconds) {
  final seconds = milliseconds < 0 ? 0 : milliseconds ~/ 1000;
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}
