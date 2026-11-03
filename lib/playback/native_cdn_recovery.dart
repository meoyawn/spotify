/// Resource selection from original FileStreamer 0x100768c84 and selector
/// 0x10076080c/848/850/860. Supplied URL strings remain opaque and unchanged.
///
/// A transient outcome moves the search after the current resource. The owner
/// still decides eligibility, pacing, cancellation and how many candidates to
/// attempt. This cursor catches no exceptions and starts no requests or timers.
final class NativeCdnResourceCursor {
  NativeCdnResourceCursor(Iterable<String> urls) : urls = List.unmodifiable(urls) {
    if (this.urls.isEmpty) throw ArgumentError('At least one supplied CDN resource is required');
  }

  final List<String> urls;
  int _currentIndex = 0;
  int _searchStart = 0;

  int get currentIndex => _currentIndex;
  String get currentUrl => urls[_currentIndex];

  /// Original selector visits every supplied entry, wrapping after the last.
  /// The caller can stop at its first eligible, unattempted resource.
  Iterable<({int index, String url})> get candidates sync* {
    final start = _searchStart;
    for (var offset = 0; offset < urls.length; offset++) {
      final index = (start + offset) % urls.length;
      yield (index: index, url: urls[index]);
    }
  }

  void select(int index) {
    RangeError.checkValidIndex(index, urls, 'index');
    _currentIndex = index;
    _searchStart = index;
  }

  /// Call only after the owning transport/source classifies a transient error.
  /// Original ordinary transient outcome1 takes this branch; source-specific
  /// outcomes such as cancellation and range fallback remain separate policy.
  void markTransientFailure() { _searchStart = _currentIndex + 1; }
}
