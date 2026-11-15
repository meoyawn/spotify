import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../protocol/native_renderer_image.dart';

/// Original album cover modal (module23424), also used by the artist header. Artwork
/// remains owned by the injected loader and is requested only after activation.
class ArtworkViewerButton extends StatefulWidget {
  const ArtworkViewerButton({super.key, required this.title, required this.label,
    required this.images, required this.imageBuilder, required this.child});
  final String title, label;
  final List<Map<String, Object?>> images;
  final Widget Function(BuildContext, Map<String, Object?>) imageBuilder;
  final Widget child;

  @override State<ArtworkViewerButton> createState() => _ArtworkViewerButtonState();
}

class _ArtworkViewerButtonState extends State<ArtworkViewerButton> {
  bool _focused = false, _showing = false;

  @override Widget build(BuildContext context) {
    final source = nativeRendererImageSource(widget.images.where((image) =>
      image['url'] is String && (image['url'] as String).isNotEmpty).toList(), desiredSize: 10000);
    if (source == null) return widget.child;
    void open() {
      if (_showing) return;
      _showing = true;
      unawaited(showDialog<void>(context: context,
        barrierLabel: 'Close artwork', barrierColor: const Color(0xbf000000),
        builder: (context) => _artworkDialog(context, widget.title, source, widget.imageBuilder))
        .whenComplete(() => _showing = false));
    }
    return Tooltip(message: widget.label, excludeFromSemantics: true,
      child: Semantics(button: true, label: widget.label, onTap: open,
        child: FocusableActionDetector(mouseCursor: SystemMouseCursors.zoomIn,
          onShowFocusHighlight: (value) => setState(() => _focused = value),
          actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) { open(); return null; })},
          child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: open,
            excludeFromSemantics: true, child: Stack(fit: StackFit.passthrough, children: [
              ExcludeSemantics(child: widget.child),
              if (_focused) Positioned.fill(child: IgnorePointer(child: DecoratedBox(
                decoration: BoxDecoration(border: Border.all(color: Colors.white, width: 2),
                  borderRadius: BorderRadius.circular(4))))),
            ])))));
  }
}

Widget _artworkDialog(BuildContext context, String title, Map<String, Object?> source,
    Widget Function(BuildContext, Map<String, Object?>) imageBuilder) {
  final viewport = MediaQuery.sizeOf(context);
  final maxWidth = viewport.width * .8, maxHeight = viewport.height * .8;
  final gap = math.min(24.0, maxHeight * .1), buttonHeight = math.min(48.0, maxHeight * .25);
  final imageHeight = maxHeight - gap - buttonHeight;
  final w = source['width'] as num?, h = source['height'] as num?;
  final knownSize = w != null && h != null && w > 0 && h > 0 && w.isFinite && h.isFinite;
  final scale = knownSize ? math.min(1.0, math.min(maxWidth / w, imageHeight / h)) : 1.0;
  return Dialog(backgroundColor: Colors.transparent, elevation: 0, insetPadding: EdgeInsets.zero,
    constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight),
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      Semantics(image: true, label: title, child: ClipRRect(borderRadius: BorderRadius.circular(8),
        child: SizedBox(width: knownSize ? w * scale : maxWidth,
          height: knownSize ? h * scale : imageHeight, child: imageBuilder(context, source)))),
      SizedBox(height: gap),
      SizedBox(height: buttonHeight, child: OutlinedButton(autofocus: true,
        style: OutlinedButton.styleFrom(foregroundColor: Colors.white,
          side: const BorderSide(color: Color(0xffb3b3b3)), padding: const EdgeInsets.symmetric(horizontal: 32),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        onPressed: () => Navigator.of(context).pop(), child: const Text('Close'))),
    ]));
}
