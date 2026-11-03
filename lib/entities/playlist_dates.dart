/// Original renderer metadata policy (Ak / AM) excludes Date added for these
/// generated formats. The native ListAttributes.format supplies the same type.
bool playlistHasDateAdded(String format) => !const {
  'daily-mix', 'my-mix', 'car-mix', 'personalized-podcasts', 'daylist', 'inspiredby-mix',
}.contains(format);

/// Playlist4 ItemAttributes.timestamp and SelectedListContent.created_at are
/// milliseconds. Zero/missing timestamps do not supply a display date.
String? playlistTimestampIso(int milliseconds) => milliseconds <= 0 || milliseconds > 8640000000000000
  ? null : DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true).toIso8601String();

/// Original component47957 and I18n formatter: relative within a strict30-day
/// window, otherwise the short-month absolute date in UTC. Current UI is en.
String playlistDateAddedLabel(Object? value, {required DateTime now}) {
  final raw = value is Map ? value['isoString'] : value;
  final date = raw is DateTime ? raw : raw is String ? DateTime.tryParse(raw) : null;
  if (date == null || date.millisecondsSinceEpoch <= 0) return '';
  final difference = date.millisecondsSinceEpoch - now.millisecondsSinceEpoch;
  if (difference.abs() >= 2592000000) return playlistAbsoluteDate(date);
  // JavaScript Math.round resolves negative half ties toward positive infinity.
  int rounded(double value) => (value + 0.5).floor();
  final seconds = difference / 1000, minutes = seconds / 60, hours = minutes / 60;
  final days = hours / 24, weeks = days / 7;
  final local = date.toLocal(), current = now.toLocal();
  final years = local.year - current.year, months = local.month - current.month + 12 * years;
  final (amount, unit) = months.abs() >= 12 ? (years, 'year')
    : rounded(weeks).abs() > 4 ? (months, 'month')
    : rounded(days).abs() >= 7 ? (rounded(weeks), 'week')
    : rounded(hours).abs() >= 24 ? (rounded(days), 'day')
    : rounded(minutes).abs() >= 60 ? (rounded(hours), 'hour')
    : rounded(seconds).abs() >= 60 ? (rounded(minutes), 'minute')
    : (rounded(seconds), 'second');
  final text = '${amount.abs()} $unit${amount.abs() == 1 ? '' : 's'}';
  // Keep the original negative-zero direction for a sub-second past date.
  return difference < 0 ? '$text ago' : 'in $text';
}

String playlistAbsoluteDate(DateTime date) {
  final utc = date.toUtc();
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${months[utc.month - 1]} ${utc.day}, ${utc.year}';
}
