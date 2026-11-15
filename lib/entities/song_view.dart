part of 'view.dart';

extension on _EntityViewState {
  void _disposeSong() {
    _songCancellation?.cancel(); _songCancellation = null;
    _songLyrics = null; _songRecommendations = null; _songRelatedAlbums = null;
    _songAlbum?.dispose(); _songAlbum = null; _songSelection = null;
    _songShowOtherArtists = false;
    _songLyricsExpanded = false; _songArtistsExpanded = false;
    _songExpandedTracks.clear();
  }

  Future<void> _showSongCredits(EntityDetails entity) async {
    final repository = widget.controller.repository;
    if (repository is! SongPageRepository) return;
    await showDialog<void>(context: context, builder: (_) => _SongCreditsDialog(
      uri: entity.uri, name: entity.name, repository: repository as SongPageRepository,
      onNavigate: widget.onNavigate));
  }

  Widget _songPage(BuildContext context, EntityDetails entity, EntityState state) => LayoutBuilder(
    builder: (context, bounds) {
      final inset = bounds.maxWidth < 600 ? 16.0 : 24.0;
      final color = _entityColor(entity);
      final lyricsFuture = _songLyricsFor(entity);
      final sections = (entity.data['songSections'] as List? ?? const []).cast<EntityJson>();
      final related = (entity.data['relatedArtists'] as List? ?? const []).cast<EntityJson>();
      final album = (entity.data['album'] as Map?)?.cast<String, Object?>();
      final albumController = album?['uri'] is String
        ? _songAlbum ??= EntityController(widget.controller.repository, uri: album!['uri'] as String) : null;
      final repository = widget.controller.repository;
      final song = repository is SongPageRepository ? repository as SongPageRepository : null;
      final otherReleases = sections.where((section) => section['otherArtist'] == true).toList();
      final visibleSections = [for (final section in sections) if (section['otherArtist'] != true) section,
        ...otherReleases.take(_songShowOtherArtists ? otherReleases.length : 5)];
      final slots = <Widget Function(BuildContext)>[
        (_) => _songIntro(entity, bounds.maxWidth, lyricsFuture),
        if (song != null) (_) {
          _songRecommendations ??= song.songRecommendations(entity.uri, cancellationToken: _songToken);
          return _songFuture(_songRecommendations!, (rows) => rows.isEmpty ? const SizedBox.shrink()
            : _songTrackSection('Recommended', rows, width: bounds.maxWidth,
              subtitle: 'Based on this song', contextUri: 'spotify:internal:recs:track-ilr',
              contextType: 'playlist', numbered: false),
            retry: _retrySongRecommendations);
        },
        for (final section in visibleSections) (_) => section['kind'] == 'tracks'
          ? _songTrackSection(section['title'] as String,
              [for (final value in section['items'] as List) EntityRow.fromJson((value as Map).cast<String, Object?>())],
              subtitle: section['subtitle'] as String?, width: bounds.maxWidth,
              contextUri: section['contextUri'] as String, contextType: section['contextType'] as String,
              expandable: true)
          : _songShelf(section),
        if (otherReleases.length > 5) (_) => Align(alignment: Alignment.centerLeft,
          child: TextButton(onPressed: _toggleSongArtists, child: Text(_songShowOtherArtists ? 'Show less' : 'Show all artists'))),
        if (song != null) (_) {
          _songRelatedAlbums ??= song.songRelatedAlbums(entity.uri, cancellationToken: _songToken);
          return _songFuture(_songRelatedAlbums!, (items) => items.isEmpty ? const SizedBox.shrink()
            : _songShelf({'title': 'Recommended releases', 'items': items,
              'seeAllUri': 'spotify:app:track:${entity.uri.split(':').last}:more-like-this'}),
            retry: _retrySongRelatedAlbums);
        },
        if (related.isNotEmpty) (_) => _songShelf({'title': 'Fans also like', 'items': related,
          'seeAllUri': entity.data['relatedArtistsUri']}),
      ];
      return CustomScrollView(key: PageStorageKey('song:${entity.uri}'), slivers: [
        SliverToBoxAdapter(child: SpotifyLinkContextMenu(uri: entity.uri,
          child: _header(context, entity, state, bounds.maxWidth, inset, color, 0))),
        if (state.phase == EntityPhase.loading) const SliverToBoxAdapter(
          child: LinearProgressIndicator(minHeight: 2, color: Color(0xff1ed760))),
        SliverToBoxAdapter(child: Container(padding: EdgeInsets.symmetric(horizontal: inset),
          decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter,
            end: Alignment.bottomCenter, colors: [Color.lerp(color, Colors.black, .60)!, const Color(0xff121212)])),
          child: Column(children: [_toolbar(context, entity, state, bounds.maxWidth),
            if (state.error != null) _error('Couldn’t refresh this song', widget.controller.refresh)]))),
        SliverPadding(padding: EdgeInsets.symmetric(horizontal: inset), sliver: SliverList.builder(
          itemCount: slots.length, itemBuilder: (context, index) => slots[index](context))),
        if (albumController != null) SliverPadding(padding: EdgeInsets.symmetric(horizontal: inset),
          sliver: _SongAlbumSliver(key: ObjectKey(albumController), controller: albumController,
            header: _songAlbumHeader(album!), rowHeight: _entityTrackRowHeight(MediaQuery.textScalerOf(context)),
            rowBuilder: (details, row, index, rows) => _songRow(details, row, index,
              playbackRows: rows, width: bounds.maxWidth, showArtwork: false, showPlays: false))),
        SliverToBoxAdapter(child: Padding(padding: EdgeInsets.fromLTRB(inset, 24, inset, 40),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if ((entity.data['release'] as Map?)?['isoString'] case final String date)
              Text(_songReleaseDate(date, (entity.data['release'] as Map?)?['precision']),
                style: _secondary.copyWith(fontSize: 12)),
            ..._copyright(entity),
            if (lyricsFuture != null) FutureBuilder<TrackLyrics>(future: lyricsFuture, builder: (context, snapshot) =>
              snapshot.data?.availability == LyricsAvailability.available && snapshot.data!.providerDisplayName.isNotEmpty
                ? Text('Lyrics provided by ${snapshot.data!.providerDisplayName}', style: _secondary.copyWith(fontSize: 11))
                : const SizedBox.shrink()),
          ]))),
      ]);
    });

  Future<TrackLyrics>? _songLyricsFor(EntityDetails entity) {
    final repository = widget.lyricsRepository;
    final image = nativeRendererImageSources(entity.images, width: 600, height: 600,
      devicePixelRatio: 1).firstOrNull?['url'] as String? ?? '';
    if (repository == null || !entity.isPlayable || image.isEmpty) return null;
    return _songLyrics ??= repository.loadSongPage(entity.uri, image, cancellationToken: _songToken);
  }

  Widget _songIntro(EntityDetails entity, double width, Future<TrackLyrics>? lyricsFuture) {
    final artists = (entity.data['songArtists'] as List? ?? const []).cast<EntityJson>();
    final artistList = _SongArtistList(artists: artists, artworkBuilder: widget.artworkBuilder,
      onNavigate: widget.onNavigate, expanded: _songArtistsExpanded, onToggle: _toggleSongArtistList);
    if (lyricsFuture == null) return artistList;
    return FutureBuilder<TrackLyrics>(future: lyricsFuture, builder: (context, snapshot) {
      final lyrics = snapshot.data;
      if (lyrics?.availability != LyricsAvailability.available || lyrics!.lines.isEmpty) return artistList;
      final body = _SongLyrics(lyrics: lyrics, previewCount: width <= 768 ? 280 : 420,
        expanded: _songLyricsExpanded, onToggle: _toggleSongLyrics);
      return Padding(padding: const EdgeInsets.only(bottom: 16), child: width < 800
        ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [body, const SizedBox(height: 32), artistList])
        : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(flex: 3, child: body), const SizedBox(width: 32), Expanded(flex: 2, child: artistList)]));
    });
  }

  Widget _songFuture<T>(Future<T> future, Widget Function(T) body, {required VoidCallback retry}) =>
    FutureBuilder<T>(future: future, builder: (context, snapshot) {
      if (snapshot.hasError) { return Padding(padding: const EdgeInsets.symmetric(vertical: 16),
        child: Row(children: [const Expanded(child: Text('Couldn’t load this section.', style: _secondary)),
          TextButton(onPressed: retry, child: const Text('Try again'))])); }
      if (!snapshot.hasData) { return const SizedBox(height: 56, child: Center(child: SizedBox.square(
        dimension: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xff1ed760))))); }
      return body(snapshot.data as T);
    });

  Widget _songShelf(EntityJson section) {
    final items = (section['items'] as List).cast<EntityJson>();
    if (items.isEmpty) return const SizedBox.shrink();
    return Padding(padding: const EdgeInsets.only(top: 32, bottom: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [Expanded(child: Text(section['title'] as String,
          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700))),
          if (section['seeAllUri'] case final String uri)
            TextButton(onPressed: widget.onNavigate == null ? null : () => widget.onNavigate!(EntityLink(
              uri: uri, name: section['title'] as String, type: uri.startsWith('spotify:app:track:') ? 'track' : 'artist')),
              child: const Text('Show all'))]),
        const SizedBox(height: 16),
        SizedBox(height: 248 * MediaQuery.textScalerOf(context).scale(1).clamp(1, 2),
          child: ListView.separated(key: PageStorageKey('song-shelf:${widget.controller.state.uri}:${section['title']}'),
            scrollDirection: Axis.horizontal, itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(width: 12),
            itemBuilder: (_, index) {
              final card = EntityDetails.fromJson(items[index]);
              return SizedBox(width: 164, child: _SongShelfCard(name: card.name,
                onPlay: widget.onPlay == null ? null : () => widget.onPlay!(EntityPlaybackSelection(entity: card)),
                child: _artistCard(items[index])));
            })),
      ]));
  }

  Widget _songTrackSection(String title, List<EntityRow> rows, {required double width,
      required String contextUri, required String contextType, String? subtitle,
      bool numbered = true, bool expandable = false}) {
    final entity = EntityDetails.fromJson({'type': contextType, 'uri': contextUri, 'name': title, 'nrTracks': rows.length});
    final key = 'song-tracks:$contextUri:$title';
    return _SongTrackSection(key: ValueKey(key), title: title, subtitle: subtitle,
      rows: rows, expandable: expandable, subtitleAbove: contextType == 'artist',
      expanded: _songExpandedTracks.contains(key), onToggle: () => _toggleSongTracks(key),
      builder: (visible) => _songRows(entity, visible, playbackRows: rows, width: width, numbered: numbered));
  }

  Widget _songRows(EntityDetails entity, List<EntityRow> rows, {required double width,
      List<EntityRow>? playbackRows, bool numbered = true, bool showArtwork = true, bool showPlays = true}) =>
    Column(children: [for (final (index, row) in rows.indexed)
      _songRow(entity, row, index, width: width, playbackRows: playbackRows ?? rows,
        numbered: numbered, showArtwork: showArtwork, showPlays: showPlays),
    ]);

  Widget _songRow(EntityDetails entity, EntityRow row, int index, {required double width,
      required List<EntityRow> playbackRows, bool numbered = true, bool showArtwork = true, bool showPlays = true}) =>
      _EntityTrackRow(key: ValueKey('${entity.uri}:${row.uri}:$index'), row: row,
        number: !numbered ? 0 : entity.type == 'album' ? row.trackNumber ?? index + 1 : index + 1,
        showArtwork: showArtwork, showAlbum: false, showDate: false, showPlays: showPlays && width >= 640,
        actionsWidth: _actionsWidth, current: _isCurrent(row), isPlaying: widget.isPlaying,
        selected: _songSelection == '${entity.uri}:$index', onNavigate: widget.onNavigate,
        artworkBuilder: widget.rowArtworkBuilder, actionsBuilder: widget.rowActionsBuilder,
        onSelect: () => _selectSongRow('${entity.uri}:$index', row),
        onPlay: widget.onPlay != null && row.canRequestPlayback ? () {
          if (_isCurrent(row) && widget.onTogglePlay != null) { widget.onTogglePlay!(); }
          else { widget.onPlay!(EntityPlaybackSelection(entity: entity, row: row, rowIndex: index, rows: playbackRows)); }
        } : null);

  Widget _songAlbumHeader(EntityJson album) {
    final details = EntityDetails.fromJson(album), link = EntityLink.fromJson(album, type: 'album');
    return Material(color: const Color(0xff282828), borderRadius: BorderRadius.circular(8), clipBehavior: Clip.antiAlias,
      child: InkWell(onTap: link == null || widget.onNavigate == null ? null : () => widget.onNavigate!(link),
        child: Row(children: [SizedBox.square(dimension: 80, child: widget.artworkBuilder?.call(context, details)
            ?? const ColoredBox(color: Color(0xff333333))),
          const SizedBox(width: 16), Expanded(child: Padding(padding: const EdgeInsets.only(right: 16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(switch (album['albumType']) { 'SINGLE' => 'From the single', 'EP' => 'From the EP',
                'COMPILATION' => 'From the compilation', _ => 'From the album' }, style: _secondary),
              const SizedBox(height: 4), Text(details.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            ]))),
        ])));
  }
}

class _SongShelfCard extends StatefulWidget {
  const _SongShelfCard({required this.name, required this.child, this.onPlay});
  final String name;
  final Widget child;
  final VoidCallback? onPlay;
  @override State<_SongShelfCard> createState() => _SongShelfCardState();
}

class _SongShelfCardState extends State<_SongShelfCard> {
  bool hovered = false, focused = false;
  @override Widget build(BuildContext context) => Focus(skipTraversal: true, canRequestFocus: false,
    onFocusChange: (value) => setState(() => focused = value),
    child: MouseRegion(onEnter: (_) => setState(() => hovered = true), onExit: (_) => setState(() => hovered = false),
      child: Stack(children: [Positioned.fill(child: widget.child),
        if ((hovered || focused) && widget.onPlay != null) Positioned(top: 104, right: 20,
          child: DesktopIconButton(tooltip: 'Play ${widget.name}', size: 48,
            backgroundColor: const Color(0xff1ed760), color: Colors.black,
            onPressed: widget.onPlay, icon: const Icon(SpotifyShellIcons.play, size: 24))),
      ])));
}

class _SongArtistList extends StatelessWidget {
  const _SongArtistList({required this.artists, this.artworkBuilder, this.onNavigate, required this.expanded, required this.onToggle});
  final List<EntityJson> artists;
  final EntityArtworkBuilder? artworkBuilder;
  final ValueChanged<EntityLink>? onNavigate;
  final bool expanded;
  final VoidCallback onToggle;
  @override Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    for (final artist in expanded ? artists : artists.take(6))
      Padding(padding: const EdgeInsets.only(bottom: 12), child: Material(color: Colors.transparent,
        borderRadius: BorderRadius.circular(4), child: InkWell(borderRadius: BorderRadius.circular(4),
          onTap: onNavigate == null ? null : () {
            final link = EntityLink.fromJson(artist, type: 'artist');
            if (link != null) onNavigate!(link);
          }, child: Padding(padding: const EdgeInsets.all(8), child: Row(children: [
            ClipOval(child: SizedBox.square(dimension: 80,
              child: artworkBuilder?.call(context, EntityDetails.fromJson(artist))
                ?? const ColoredBox(color: Color(0xff282828)))),
            const SizedBox(width: 16), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Artist', style: TextStyle(fontSize: 14)), const SizedBox(height: 6),
              Text(artist['name'] as String, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            ])),
          ]))))),
    if (artists.length > 6) Align(alignment: Alignment.centerLeft,
      child: TextButton(onPressed: onToggle,
        child: Text(expanded ? 'Show less' : 'Show all artists'))),
  ]);
}

class _SongLyrics extends StatelessWidget {
  const _SongLyrics({required this.lyrics, required this.previewCount, required this.expanded, required this.onToggle});
  final TrackLyrics lyrics;
  final int previewCount;
  final bool expanded;
  final VoidCallback onToggle;
  @override Widget build(BuildContext context) {
    var characters = 0, count = 0;
    for (final line in lyrics.lines) {
      characters += line.words.length;
      if (characters > previewCount) break;
      count++;
    }
    final lines = expanded ? lyrics.lines : lyrics.lines.take(count);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Lyrics', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700)), const SizedBox(height: 24),
      for (final line in lines) Padding(padding: EdgeInsets.only(bottom: line.words.isEmpty ? 12 : 4),
        child: Text(line.words, style: const TextStyle(fontSize: 16, height: 1.5, color: Color(0xffb3b3b3)))),
      if (count < lyrics.lines.length) TextButton(onPressed: onToggle,
        style: TextButton.styleFrom(padding: EdgeInsets.zero, foregroundColor: Colors.white),
        child: Text(expanded ? 'Show less' : '… Show more', style: const TextStyle(fontWeight: FontWeight.w700))),
    ]);
  }
}

class _SongTrackSection extends StatelessWidget {
  const _SongTrackSection({super.key, required this.title, this.subtitle, required this.rows,
    required this.expandable, required this.builder, required this.subtitleAbove,
    required this.expanded, required this.onToggle});
  final String title;
  final String? subtitle;
  final List<EntityRow> rows;
  final bool expandable, subtitleAbove, expanded;
  final VoidCallback onToggle;
  final Widget Function(List<EntityRow>) builder;
  @override Widget build(BuildContext context) {
    return Padding(padding: const EdgeInsets.only(top: 32),
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (subtitleAbove && subtitle != null) Padding(padding: const EdgeInsets.only(bottom: 8),
        child: Text(subtitle!, style: _secondary)),
      Text(title, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
      if (!subtitleAbove && subtitle != null) Padding(padding: const EdgeInsets.only(top: 8),
        child: Text(subtitle!, style: _secondary)),
      const SizedBox(height: 16), builder(expandable && !expanded ? rows.take(5).toList() : rows),
      if (expandable && rows.length > 5) Align(alignment: Alignment.centerLeft,
        child: TextButton(onPressed: onToggle,
          child: Text(expanded ? 'Show less' : 'See more'))),
    ]));
  }
}

class _SongAlbumSliver extends StatefulWidget {
  const _SongAlbumSliver({super.key, required this.controller, required this.header, required this.rowBuilder, required this.rowHeight});
  final EntityController controller;
  final Widget header;
  final double rowHeight;
  final Widget Function(EntityDetails, EntityRow, int, List<EntityRow>) rowBuilder;
  @override State<_SongAlbumSliver> createState() => _SongAlbumSliverState();
}

class _SongAlbumSliverState extends State<_SongAlbumSliver> {
  bool requested = false;
  @override Widget build(BuildContext context) => SliverLayoutBuilder(builder: (context, constraints) {
    if (!requested && constraints.remainingCacheExtent > 0) {
      requested = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(widget.controller.initialize());
      });
    }
    return ListenableBuilder(listenable: widget.controller, builder: (context, _) {
        final state = widget.controller.state;
        final rows = state.rows.where((row) => !row.isDisc).toList(growable: false);
        return SliverMainAxisGroup(slivers: [
          SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.only(top: 32, bottom: 12), child: widget.header)),
          if (state.details != null) SliverFixedExtentList.builder(itemExtent: widget.rowHeight,
            itemCount: rows.length, itemBuilder: (context, index) => widget.rowBuilder(state.details!, rows[index], index, state.rows)),
          if (state.phase == EntityPhase.loading) const SliverToBoxAdapter(child: SizedBox(height: 56,
            child: Center(child: CircularProgressIndicator(color: Color(0xff1ed760))))),
          if (state.phase == EntityPhase.failed) SliverToBoxAdapter(child: TextButton(onPressed: widget.controller.refresh,
            child: const Text('Couldn’t load album tracks. Try again'))),
          if (state.hasMore) SliverToBoxAdapter(child: TextButton(onPressed: state.isLoadingMore ? null : widget.controller.loadMore,
            child: Text(state.isLoadingMore ? 'Loading…' : 'Show more tracks'))),
        ]);
      });
  });
}

class _SongCreditsDialog extends StatefulWidget {
  const _SongCreditsDialog({required this.uri, required this.name, required this.repository, this.onNavigate});
  final String uri, name;
  final SongPageRepository repository;
  final ValueChanged<EntityLink>? onNavigate;
  @override State<_SongCreditsDialog> createState() => _SongCreditsDialogState();
}

class _SongCreditsDialogState extends State<_SongCreditsDialog> {
  final cancellation = CancellationToken();
  late Future<EntityJson> credits = widget.repository.songCredits(widget.uri, cancellationToken: cancellation);
  @override void dispose() { cancellation.cancel(); super.dispose(); }
  @override Widget build(BuildContext context) => Dialog(backgroundColor: const Color(0xff282828),
    child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 560, maxHeight: 680),
      child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [const Expanded(child: Text('Credits', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700))),
            DesktopIconButton(tooltip: 'Close credits', icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context))]),
          const SizedBox(height: 16), Text(widget.name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
          const SizedBox(height: 24), Flexible(child: FutureBuilder<EntityJson>(future: credits, builder: (context, snapshot) {
            if (snapshot.hasError) { return TextButton(onPressed: () => setState(() => credits =
              widget.repository.songCredits(widget.uri, cancellationToken: cancellation)), child: const Text('Couldn’t load credits. Try again')); }
            if (!snapshot.hasData) return const Center(child: CircularProgressIndicator(color: Color(0xff1ed760)));
            return SingleChildScrollView(child: _songCreditContents(context, snapshot.data!, widget.onNavigate));
          })),
        ]))));
}

Widget _songCreditContents(BuildContext context, EntityJson data, ValueChanged<EntityLink>? onNavigate) {
  final track = (data['trackUnion'] as Map?)?.cast<String, Object?>() ?? data;
  final credits = (track['creditsTrait'] as Map?)?.cast<String, Object?>() ?? const <String, Object?>{};
  final mainArtists = {for (final artist in (track['artists'] as Map?)?['items'] as List? ?? const [])
    (artist as Map)['uri']};
  final groups = <String, Map<String, EntityJson>>{};
  for (final value in (credits['contributors'] as Map?)?['items'] as List? ?? const []) {
    final person = (value as Map).cast<String, Object?>();
    final name = person['name'] as String? ?? '';
    if (name.isEmpty) continue;
    final group = (person['roleGroup'] as Map?)?['name'] as String? ?? 'Other';
    final people = groups.putIfAbsent(group, () => {});
    final candidate = person['uri'] ?? (person['reference'] as Map?)?['uri'];
    final entry = people.putIfAbsent(name, () => {'name': name, 'roles': <String>[],
      'uri': null, 'url': null});
    if (group == groups.keys.first && mainArtists.contains(candidate)) { entry['uri'] ??= candidate; }
    if (entry['uri'] == null) { entry['url'] ??= person['url'] ?? (person['reference'] as Map?)?['url']; }
    if (person['role'] case final String role) (entry['roles'] as List<String>).add(role);
  }
  final sources = (credits['sources'] as Map?)?['items'] as List? ?? const [];
  return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    for (final (index, group) in groups.entries.indexed) ...[
      Text(group.key,
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)), const SizedBox(height: 8),
      for (final person in group.value.values)
        Padding(padding: const EdgeInsets.only(bottom: 8),
          child: _SongCreditPerson(person: person,
            onTap: index == 0 && mainArtists.contains(person['uri']) && onNavigate != null
              ? () { Navigator.pop(context); onNavigate(EntityLink(uri: person['uri'] as String,
                  name: person['name'] as String, type: 'artist')); }
              : person['url'] is String && const {'https', 'http'}.contains(Uri.tryParse(person['url'] as String)?.scheme)
                ? () => unawaited(const DesktopHost().openExternalUrl(person['url'] as String).catchError((Object _) {
                    if (context.mounted) showSpotifySnackBar(context, 'Couldn’t open this link.'); })) : null)),
      const SizedBox(height: 24),
    ],
    if (groups.isEmpty) const Text('Credits aren’t available for this song.', style: _secondary),
    if (sources.isNotEmpty) Text('Source: ${sources.map((source) => (source as Map)['name']).join(', ')}',
      style: _secondary.copyWith(fontSize: 12)),
  ]);
}

class _SongCreditPerson extends StatelessWidget {
  const _SongCreditPerson({required this.person, this.onTap});
  final EntityJson person;
  final VoidCallback? onTap;
  @override Widget build(BuildContext context) => InkWell(onTap: onTap,
    child: Padding(padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(person['name'] as String, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
        const SizedBox(height: 4), Text((person['roles'] as List<String>).join(', '), style: _secondary),
      ])));
}

String _songReleaseDate(String value, Object? precision) {
  final date = DateTime.tryParse(value);
  if (date == null) return value;
  const months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August',
    'September', 'October', 'November', 'December'];
  if (precision == 'YEAR') return '${date.year}';
  if (precision == 'MONTH') return '${months[date.month - 1]} ${date.year}';
  return '${months[date.month - 1]} ${date.day}, ${date.year}';
}
