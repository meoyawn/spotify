import 'dart:async';

import 'package:flutter/material.dart';

import '../library/saved_tracks_controller.dart';
import 'desktop_icon_button.dart';

/// All placements share the same controller; a failed read stays unknown and
/// a failed write restores the last acknowledged state.
class TrackSaveButton extends StatefulWidget {
  const TrackSaveButton({super.key, required this.controller, required this.uri,
    required this.onError, this.size = 32, this.iconSize = 20});
  final SavedTracksController controller;
  final String uri;
  final ValueChanged<Object> onError;
  final double size, iconSize;

  @override State<TrackSaveButton> createState() => _TrackSaveButtonState();
}

class _TrackSaveButtonState extends State<TrackSaveButton> {
  SavedTrackState _state = const SavedTrackState();
  @override void initState() { super.initState(); _watch(); _load(); }
  @override void didUpdateWidget(TrackSaveButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller != oldWidget.controller || widget.uri != oldWidget.uri) {
      oldWidget.controller.removeListener(_changed);
      _watch(); _load();
    }
  }

  void _watch() {
    _state = widget.controller.state(widget.uri);
    widget.controller.addListener(_changed);
  }

  void _changed() {
    final next = widget.controller.state(widget.uri);
    // Recycling one new row can resolve its membership without rebuilding
    // every other mounted save control in the playlist and player panels.
    if (identical(next, _state)) return;
    setState(() => _state = next);
  }

  @override void reassemble() {
    super.reassemble();
    widget.controller.removeListener(_changed);
    _watch();
  }

  @override void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  void _load() {
    // Failed background membership reads are represented on the control. They
    // are retried only on user action, never by the build or playback tick.
    unawaited(widget.controller.load(widget.uri).catchError((Object _) {}));
  }

  Future<void> _toggle() async {
    final pending = widget.controller.state(widget.uri).changing;
    try { await widget.controller.toggle(widget.uri); }
    catch (error) { if (mounted && !pending) widget.onError(error); }
  }

  Future<void> _retry() async {
    try { await widget.controller.load(widget.uri); }
    catch (error) { if (mounted) widget.onError(error); }
  }

  @override Widget build(BuildContext context) {
    final state = _state;
    final saved = state.saved == true;
    final unknown = state.saved == null;
    final label = saved ? 'Remove from Liked Songs' : 'Add to Liked Songs';
    return DesktopIconButton(tooltip: unknown ? state.error == null
        ? 'Checking Liked Songs…' : 'Retry Liked Songs status' : label,
      onPressed: unknown ? state.error == null ? null : _retry : _toggle,
      size: widget.size, padding: const EdgeInsets.all(6),
      color: saved ? const Color(0xff1ed760) : const Color(0xffb3b3b3),
      icon: unknown && state.error == null ? SizedBox.square(dimension: widget.iconSize - 3,
        child: const CircularProgressIndicator(strokeWidth: 2, color: Color(0xff1ed760)))
        : Icon(saved ? Icons.check_circle : Icons.add_circle_outline, size: widget.iconSize));
  }
}
