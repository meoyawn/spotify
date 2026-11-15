import 'dart:async';

import 'package:cancellation_token/cancellation_token.dart';
import 'package:flutter/material.dart';

import '../app/snack_bar.dart';
import 'artist_about_repository.dart';

/// Artist route and Now Playing share optimistic Library membership.
class ArtistFollowButton extends StatefulWidget {
  const ArtistFollowButton({super.key, required this.uri, required this.name,
    required this.repository, this.onLibraryChanged, this.compact = false});
  final String uri, name;
  final ArtistAboutRepository repository;
  final VoidCallback? onLibraryChanged;
  final bool compact;
  @override State<ArtistFollowButton> createState() => _ArtistFollowButtonState();
}

class _ArtistFollowButtonState extends State<ArtistFollowButton> {
  CancellationToken _request = CancellationToken();
  bool _failed = false;

  @override void initState() { super.initState(); unawaited(_load(_request)); }
  @override void didUpdateWidget(ArtistFollowButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.uri == widget.uri && oldWidget.repository == widget.repository) return;
    _request.cancel(); _request = CancellationToken(); _failed = false;
    unawaited(_load(_request));
  }
  Future<void> _load(CancellationToken token) async {
    if (widget.repository.following(widget.uri) != null) return;
    try {
      await widget.repository.loadFollowing(widget.uri, cancellationToken: token);
      if (mounted && !token.isCancelled) setState(() => _failed = false);
    } catch (_) {
      if (mounted && !token.isCancelled) setState(() => _failed = true);
    }
  }
  Future<void> _toggle() async {
    final token = _request;
    final following = widget.repository.following(widget.uri);
    if (following == null) {
      setState(() => _failed = false);
      await _load(token);
      return;
    }
    final pending = widget.repository.changingFollowing(widget.uri);
    try {
      await widget.repository.setFollowing(widget.uri, !following,
        cancellationToken: token, onLibraryChanged: widget.onLibraryChanged);
    } catch (_) {
      if (mounted && !token.isCancelled && !pending) showSpotifySnackBar(context, 'Couldn’t update followed artists. Try again.');
    }
  }
  @override void dispose() { _request.cancel(); super.dispose(); }

  @override Widget build(BuildContext context) => ListenableBuilder(listenable: widget.repository,
    builder: (context, _) {
      final following = widget.repository.following(widget.uri);
      final retry = following == null && _failed;
      final busy = following == null && !retry;
      return Tooltip(message: retry ? 'Retry follow status'
        : following == true ? 'Unfollow ${widget.name}' : 'Follow ${widget.name}',
        child: OutlinedButton(onPressed: busy ? null : _toggle,
          style: OutlinedButton.styleFrom(foregroundColor: Colors.white,
            side: const BorderSide(color: Color(0xff7c7c7c)), shape: const StadiumBorder(),
            minimumSize: Size(0, widget.compact ? 32 : 36),
            padding: EdgeInsets.symmetric(horizontal: widget.compact ? 16 : 24),
            textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
          child: busy
            ? const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xffb3b3b3)))
            : Text(retry ? 'Retry' : following == true ? 'Following' : 'Follow')));
    });
}
