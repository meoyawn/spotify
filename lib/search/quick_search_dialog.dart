import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cancellation_token/cancellation_token.dart';

import 'models.dart';
import 'repository.dart';
import 'view.dart' show SearchArtworkBuilder;

class QuickSearchChoice {
  const QuickSearchChoice(this.uri, {this.item});
  final String uri;
  final SearchItem? item;
}

/// Original desktop quick-search layout and shortcuts (proprietary cS/ci in
/// chunk bfb65aab...). Its separate request producer is independently captured
/// in reverse-engineering/fixtures/search-modal-original.json.
class QuickSearchDialog extends StatefulWidget {
  const QuickSearchDialog({super.key, this.repository, this.artworkBuilder,
    this.onPlay, this.canPlay});
  final SearchModalRepository? repository;
  final SearchArtworkBuilder? artworkBuilder;
  final ValueChanged<SearchItem>? onPlay;
  final bool Function(SearchItem)? canPlay;

  @override
  State<QuickSearchDialog> createState() => _QuickSearchDialogState();
}

class _QuickSearchDialogState extends State<QuickSearchDialog> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  CancellationToken _request = CancellationToken();
  final _cache = <String, ({SearchPage page, DateTime saved})>{};
  List<SearchItem> _items = const [];
  int _selected = 0, _revision = 0;
  bool _loading = false, _failed = false, _closing = false;
  String? _directUri;

  static String? _entityUri(String value) {
    if (RegExp(r'^spotify:(track|album|artist|playlist|episode|show|audiobook):[A-Za-z0-9]{22}$').hasMatch(value)) {
      return value;
    }
    if (RegExp(r'^spotify:user:[^:]+:playlist:[A-Za-z0-9]{22}$').hasMatch(value)) return value;
    final url = Uri.tryParse(value);
    if (url == null || !const {'https', 'http'}.contains(url.scheme) ||
        !const {'open.spotify.com', 'play.spotify.com'}.contains(url.host)) return null;
    final parts = url.pathSegments.toList();
    if (parts.isNotEmpty && parts.first.startsWith('intl-')) parts.removeAt(0);
    if (parts.length != 2 || !const {'track', 'album', 'artist', 'playlist', 'episode', 'show', 'audiobook'}.contains(parts.first) ||
        !RegExp(r'^[A-Za-z0-9]{22}$').hasMatch(parts.last)) return null;
    return 'spotify:${parts.first}:${parts.last}';
  }

  Future<void> _queryChanged(String query) async {
    _request.cancel();
    final token = _request = CancellationToken();
    final revision = ++_revision, direct = _entityUri(query), repository = widget.repository;
    final enabled = direct == null && query.trim().isNotEmpty && repository != null;
    final cached = _cache[query];
    final fresh = cached != null && DateTime.now().difference(cached.saved) < const Duration(minutes: 5);
    setState(() {
      _selected = 0;
      _directUri = direct;
      _loading = enabled && !fresh;
      _failed = false;
      _items = fresh && enabled ? cached!.page.items : const [];
    });
    if (!enabled || fresh) return;
    try {
      final page = await repository!.modal(query, cancellationToken: token);
      token.throwIfCancelled();
      _cache[query] = (page: page, saved: DateTime.now());
      while (_cache.length > 24) { _cache.remove(_cache.keys.first); }
      if (!mounted || revision != _revision) return;
      setState(() { _items = page.items; _loading = false; });
    } on CancelledException { return; } catch (_) {
      if (!mounted || revision != _revision) return;
      setState(() { _items = const []; _loading = false; _failed = true; });
    }
  }

  SearchItem? get _current => _items.isEmpty ? null : _items[_selected.clamp(0, _items.length - 1).toInt()];

  bool _canPlay(SearchItem item) => widget.onPlay != null &&
    const {'album', 'artist', 'track', 'playlist', 'episode', 'show', 'audiobook'}.contains(item.type) &&
    (widget.canPlay?.call(item) ?? true);

  void _move(int delta) {
    if (_items.isEmpty) return;
    setState(() => _selected = (_selected + delta).clamp(0, _items.length - 1).toInt());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final top = _selected * 68.0, bottom = (_selected + 1) * 68.0;
      final offset = _scroll.offset, height = _scroll.position.viewportDimension;
      final target = top < offset ? top : bottom > offset + height ? bottom - height : offset;
      _scroll.jumpTo(target.clamp(0.0, _scroll.position.maxScrollExtent));
    });
  }

  void _activate({bool play = false}) {
    if (_closing) return;
    final direct = _directUri;
    if (direct != null) { _close(QuickSearchChoice(direct)); return; }
    final current = _current;
    if (current == null) return;
    if (play) {
      // Original Shift+Enter starts playback while retaining the modal.
      if (_canPlay(current)) widget.onPlay!(current);
    } else {
      _close(QuickSearchChoice(current.uri, item: current));
    }
  }

  void _close([QuickSearchChoice? choice]) {
    if (_closing) return;
    _closing = true;
    Navigator.of(context).pop(choice);
  }

  @override
  void dispose() {
    _request.cancel();
    _revision++;
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final current = _current;
    final canOpen = current != null || _directUri != null;
    final canPlay = current != null && _canPlay(current);
    final height = (MediaQuery.sizeOf(context).height - 80).clamp(180.0, 860.0).toDouble();
    return Dialog(backgroundColor: const Color(0xff181818), surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 770),
        child: SizedBox(width: 770, height: height, child: CallbackShortcuts(bindings: {
          const SingleActivator(LogicalKeyboardKey.arrowUp): () => _move(-1),
          const SingleActivator(LogicalKeyboardKey.arrowDown): () => _move(1),
          const SingleActivator(LogicalKeyboardKey.enter): () => _activate(),
          const SingleActivator(LogicalKeyboardKey.enter, shift: true): () => _activate(play: true),
          const SingleActivator(LogicalKeyboardKey.escape): () => _close(),
        }, child: Padding(padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SizedBox(height: 52, child: TextField(controller: _input, autofocus: true,
              onChanged: (query) => unawaited(_queryChanged(query)),
              onSubmitted: (_) => _activate(play: HardwareKeyboard.instance.isShiftPressed),
              cursorColor: Colors.black, textInputAction: TextInputAction.search,
              style: const TextStyle(color: Colors.black, fontSize: 16),
              decoration: InputDecoration(filled: true, fillColor: Colors.white,
                hintText: 'What do you want to play?',
                hintStyle: const TextStyle(color: Color(0xff727272), fontSize: 16),
                prefixIcon: const Icon(Icons.search, color: Colors.black, size: 28),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                border: OutlineInputBorder(borderSide: BorderSide.none, borderRadius: BorderRadius.circular(500)),
                focusedBorder: OutlineInputBorder(borderSide: BorderSide.none, borderRadius: BorderRadius.circular(500))))),
            Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
              child: LayoutBuilder(builder: (context, constraints) {
                final hints = [
                  _instruction(const ['↑', '↓'], 'Navigate', _items.isNotEmpty),
                  _instruction(const ['Enter'], 'Open', canOpen),
                  _instruction(const ['Shift', 'Enter'], 'Play', canPlay),
                ];
                return constraints.maxWidth >= 480
                  ? Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: hints)
                  : Wrap(spacing: 16, runSpacing: 8, children: hints);
              })),
            if (_loading) const LinearProgressIndicator(minHeight: 2, color: Color(0xffb3b3b3)),
            Expanded(child: _items.isEmpty ? _empty() : ListView.builder(
              controller: _scroll, padding: EdgeInsets.zero, itemExtent: 68,
              itemCount: _items.length, itemBuilder: (context, index) {
                final item = _items[index];
                return Semantics(selected: _selected == index, child: Material(
                  color: _selected == index ? const Color(0xff303030) : Colors.transparent,
                  borderRadius: BorderRadius.circular(4), child: InkWell(
                    canRequestFocus: false, borderRadius: BorderRadius.circular(4),
                    hoverColor: const Color(0xff303030),
                    onTap: () => _close(QuickSearchChoice(item.uri, item: item)),
                    child: Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      child: Row(children: [
                        ClipRRect(borderRadius: BorderRadius.circular(
                          const {'artist', 'author', 'user'}.contains(item.type) ? 24 : 4),
                          child: SizedBox.square(dimension: 48,
                            child: widget.artworkBuilder?.call(context, item) ?? ColoredBox(
                              color: const Color(0xff282828), child: Icon(
                                const {'artist', 'author', 'user'}.contains(item.type)
                                  ? Icons.person_outline : Icons.music_note,
                                color: const Color(0xffb3b3b3), size: 24)))),
                        const SizedBox(width: 16),
                        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center, children: [
                            Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white, fontSize: 16)),
                            if (item.contributors.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text(item.contributors.join(', '), maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: Color(0xffb3b3b3), fontSize: 14)),
                            ],
                          ])),
                        const SizedBox(width: 16),
                        Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                          decoration: BoxDecoration(color: const Color(0xff3e3e3e),
                            borderRadius: BorderRadius.circular(4)),
                          child: Text(_type(item.type), style: const TextStyle(
                            color: Color(0xffb3b3b3), fontSize: 14))),
                      ])))));
              })),
          ]))))));
  }

  Widget _empty() {
    final message = widget.repository == null ? 'Log in to search Spotify.'
      : _directUri != null ? 'Press Enter to open this Spotify link.'
      : _loading ? '' : _failed ? 'Couldn’t load search results.'
      : _input.text.trim().isEmpty ? '' : 'No results found for “${_input.text}”.';
    return Center(child: Padding(padding: const EdgeInsets.all(24),
      child: Text(message, style: const TextStyle(color: Color(0xffb3b3b3), fontSize: 16),
        textAlign: TextAlign.center)));
  }

  Widget _instruction(List<String> keys, String label, bool enabled) => Opacity(
    opacity: enabled ? 1 : 0.45, child: Row(mainAxisSize: MainAxisSize.min, children: [
      for (final key in keys) ...[
        Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          decoration: BoxDecoration(border: Border.all(color: const Color(0xff8b8b8b)),
            borderRadius: BorderRadius.circular(4)),
          child: Text(key, style: const TextStyle(color: Color(0xffb3b3b3), fontSize: 11))),
        const SizedBox(width: 4),
      ],
      Text(label, style: const TextStyle(color: Color(0xffb3b3b3), fontSize: 12)),
    ]));

  static String _type(String type) => const {
    'track': 'Track', 'artist': 'Artist', 'album': 'Album', 'playlist': 'Playlist',
    'show': 'Podcast', 'episode': 'Episode', 'audiobook': 'Audiobook',
    'author': 'Author', 'user': 'Profile', 'genre': 'Genre',
  }[type] ?? type;
}
