import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:cancellation_token/cancellation_token.dart';

import '../protocol/native_renderer_image.dart';

/// Decodes only bytes returned by the original-field image client. Supplying
/// artwork never enables Flutter's default network image HTTP implementation.
class SpotifyArtwork extends StatefulWidget {
  const SpotifyArtwork({super.key, required this.images, required this.load,
    this.round = false, this.prepare, this.alignment = Alignment.center, this.borderRadius = 4});
  final List<Map<String, Object?>> images;
  final Future<Uint8List> Function(String rawUrl, {CancellationToken? cancellationToken}) load;
  final bool round;
  final Alignment alignment;
  final double borderRadius;
  final Future<void> Function(CancellationToken)? prepare;
  @override State<SpotifyArtwork> createState() => _SpotifyArtworkState();
}

class _SpotifyArtworkState extends State<SpotifyArtwork> {
  CancellationToken _request = CancellationToken();
  CancellationToken? _preparation;
  bool? _preparing;

  @override void initState() { super.initState(); _prepare(); }
  @override void didUpdateWidget(SpotifyArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.alignment != widget.alignment || oldWidget.borderRadius != widget.borderRadius) { _content = null; }
    if (widget.prepare == null) _preparation?.cancel();
    else if (_preparing != true && widget.prepare != oldWidget.prepare) _prepare();
  }

  void _prepare() {
    final prepare = widget.prepare;
    if (prepare == null) return;
    _preparation?.cancel();
    final token = _preparation = CancellationToken();
    _preparing = true;
    unawaited(Future.sync(() => prepare(token)).then<void>((_) {}, onError: (Object error) {
      if (error is! CancelledException && !token.isCancelled) debugPrint('Artwork preparation: $error');
    }).whenComplete(() { if (identical(_preparation, token)) _preparing = false; }));
  }
  String? _url;
  Future<Uint8List>? _bytes;
  int? _decodeWidth;
  Widget? _content;
  bool? _contentRound;
  @override void reassemble() {
    super.reassemble();
    _request.cancel();
    _url = null;
    _bytes = null;
    _content = null;
  }
  void _resolve(double width, double height) {
    final candidates = widget.images.where((image) => image['url'] is String &&
      (image['url'] as String).isNotEmpty).toList();
    final ratio = MediaQuery.devicePixelRatioOf(context), desired = width * ratio;
    // ResizeImage keys include the decode width. Rounding upward to a bounded
    // step keeps one bitmap across nearby sizes instead of decoding another
    // large cover for every pixel of a live window/sidebar resize. The original
    // source URL selection below still receives the exact layout dimensions.
    final step = desired <= 128 ? 16 : 64;
    final decodeWidth = desired.isFinite && desired > 0
      ? ((desired.ceil() + step - 1) ~/ step) * step : null;
    if (decodeWidth != _decodeWidth) {
      _decodeWidth = decodeWidth;
      _content = null;
    }
    final sources = nativeRendererImageSources(candidates, width: width, height: height,
      devicePixelRatio: ratio);
    final url = sources.firstOrNull?['url'] as String?;
    if (url == _url) return;
    _request.cancel(); _request = CancellationToken();
    _url = url;
    _bytes = url == null ? null : widget.load(url, cancellationToken: _request);
    _content = null;
  }
  @override void dispose() { _request.cancel(); _preparation?.cancel(); super.dispose(); }
  @override Widget build(BuildContext context) => LayoutBuilder(builder: (context, constraints) {
    final width = constraints.maxWidth.isFinite && constraints.maxWidth > 0 ? constraints.maxWidth : 48.0;
    final height = constraints.maxHeight.isFinite && constraints.maxHeight > 0 ? constraints.maxHeight : width;
    _resolve(width, height);
    if (_content != null && _contentRound == widget.round) return _content!;
    _contentRound = widget.round;
    final decodeWidth = _decodeWidth;
    final image = FutureBuilder<Uint8List>(key: ValueKey(_url), future: _bytes, builder: (context, snapshot) {
      if (snapshot.hasData) {
        return Image.memory(snapshot.data!, fit: BoxFit.cover, alignment: widget.alignment, cacheWidth: decodeWidth,
          errorBuilder: (_, _, _) => _placeholder());
      }
      return _placeholder();
    });
    return _content = widget.round ? ClipOval(child: image) :
      ClipRRect(borderRadius: BorderRadius.circular(widget.borderRadius), child: image);
  });
  Widget _placeholder() => const ColoredBox(color: Color(0xff282828),
    child: Center(child: Icon(Icons.music_note, color: Color(0xffa7a7a7), size: 24)));
}
