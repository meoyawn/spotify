import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// GitHub Actions release steps for macOS:
///
/// - `prepare`: reserve the next `vX.Y.Z` tag for the pushed main commit.
/// - `signing-setup` / `signing-cleanup`: ephemeral Developer ID keychain.
/// - `package`: notarize the signed app and wrap it in a notarized DMG.
/// - `publish`: upload the DMG to the tag's GitHub release.
const _repository = 'meoyawn/spotify';
const _branch = 'main';
const _manifest = 'pubspec.yaml';
const _app = 'spotify_flutter.app';
const _bundleId = 'dev.meoyawn.spotifyFlutter';
const _products = 'build/macos/Build/Products/Release';

final _root = File.fromUri(Platform.script).parent.parent.resolveSymbolicLinksSync();

void main(List<String> arguments) {
  const commands = {'prepare', 'signing-setup', 'signing-cleanup', 'package', 'publish'};
  if (arguments.length != 1 || !commands.contains(arguments.single)) {
    stderr.writeln('Usage: dart run tools/release_ci.dart <${commands.join('|')}>');
    exit(64);
  }
  switch (arguments.single) {
    case 'prepare': _prepare();
    case 'signing-setup': _signingSetup();
    case 'signing-cleanup': _signingCleanup();
    case 'package': _package();
    case 'publish': _publish();
  }
}

// Versions ------------------------------------------------------------------

typedef Version = ({int major, int minor, int patch, int build});

final _versionLine = RegExp(r'^version: ([^\s]+)[ \t]*$', multiLine: true);
final _versionPattern = RegExp(r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\+([1-9][0-9]*)$');
final _tagPattern = RegExp(r'^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$');
final _sourceTrailer = RegExp(r'^Source-commit: ([0-9a-f]{40})$', multiLine: true);

Version _version(String manifest) {
  final lines = _versionLine.allMatches(manifest).toList();
  final match = lines.length == 1 ? _versionPattern.firstMatch(lines.single.group(1)!) : null;
  if (match == null) throw FormatException('Expected one `version: X.Y.Z+N` line in $_manifest');
  final parts = [for (var index = 1; index <= 4; index++) int.parse(match.group(index)!)];
  return (major: parts[0], minor: parts[1], patch: parts[2], build: parts[3]);
}

Version? _tagVersion(String tag) {
  final match = _tagPattern.firstMatch(tag);
  if (match == null) return null;
  final parts = [for (var index = 1; index <= 3; index++) int.parse(match.group(index)!)];
  return (major: parts[0], minor: parts[1], patch: parts[2], build: 0);
}

int _compare(Version left, Version right) {
  for (final comparison in [left.major.compareTo(right.major),
      left.minor.compareTo(right.minor), left.patch.compareTo(right.patch)]) {
    if (comparison != 0) return comparison;
  }
  return 0;
}

/// The manifest version wins when it is ahead of every release (a manual
/// minor/major bump); otherwise the latest release's patch is incremented.
Version _next(Version base, Version? latest) {
  if (latest == null) return base;
  final build = max(base.build, latest.build + 1);
  if (_compare(base, latest) > 0) return (major: base.major, minor: base.minor, patch: base.patch, build: build);
  return (major: latest.major, minor: latest.minor, patch: latest.patch + 1, build: build);
}

String _tag(Version version) => 'v${version.major}.${version.minor}.${version.patch}';
String _versionString(Version version) => '${_tag(version).substring(1)}+${version.build}';

// prepare -------------------------------------------------------------------

void _prepare() {
  final source = _requireGitHubPush();
  final output = _env('GITHUB_OUTPUT');
  if (_git(['rev-parse', 'HEAD']).trim() != source) throw StateError('Checkout differs from GITHUB_SHA');
  if (_git(['status', '--porcelain=v1', '--untracked-files=no']).isNotEmpty) throw StateError('Release preparation requires a clean checkout');
  _git(['fetch', '--no-recurse-submodules', '--tags', 'origin', _branch]);
  if (_git(['rev-parse', 'FETCH_HEAD']).trim() != source) {
    stdout.writeln('Skipping a superseded $_branch commit.');
    return;
  }

  final manifest = File('$_root/$_manifest').readAsStringSync();
  final base = _version(manifest);
  Version? latest;
  String? existing;
  for (final tag in _git(['tag', '--list', 'v*']).split('\n')) {
    final tagged = _tagVersion(tag);
    if (tagged == null) continue;
    final commit = _git(['rev-parse', '$tag^{commit}']).trim();
    final parents = _git(['rev-list', '--parents', '-n', '1', commit]).trim().split(' ');
    final trailer = _sourceTrailer.firstMatch(_git(['show', '-s', '--format=%B', commit]))?.group(1);
    if (parents.length != 2 || trailer != parents[1]) throw StateError('$tag is not a release commit');
    final version = _version(_git(['show', '$tag:$_manifest']));
    if (_compare(tagged, version) != 0) throw StateError('$tag does not match its $_manifest version');
    if (trailer == source) {
      if (existing != null) throw StateError('Several release tags share source $source');
      existing = tag;
    }
    if (latest == null || _compare(version, latest) > 0) latest = version;
  }
  if (existing != null) {
    File(output).writeAsStringSync('tag=$existing\n', mode: FileMode.append);
    stdout.writeln('Reusing $existing for source $source.');
    return;
  }

  // The release commit is a child of the pushed commit carrying only the
  // version bump. It is reachable from its tag, never pushed to main.
  final next = _next(base, latest);
  final tag = _tag(next);
  File('$_root/$_manifest').writeAsStringSync(manifest.replaceFirst(_versionLine, 'version: ${_versionString(next)}'));
  final date = _git(['show', '-s', '--format=%cI', source]).trim();
  _git(['-c', 'user.name=github-actions[bot]',
    '-c', 'user.email=41898282+github-actions[bot]@users.noreply.github.com',
    '-c', 'commit.gpgsign=false', 'commit', '--quiet', '--allow-empty', '--only', _manifest,
    '-m', 'Release $tag', '-m', 'Source-commit: $source'],
    environment: {'GIT_AUTHOR_DATE': date, 'GIT_COMMITTER_DATE': date});
  _git(['tag', tag]);
  _git(['push', 'origin', 'refs/tags/$tag']);
  File(output).writeAsStringSync('tag=$tag\n', mode: FileMode.append);
  stdout.writeln('Reserved $tag (${_versionString(next)}) for source $source.');
}

String _requireGitHubPush() {
  final source = Platform.environment['GITHUB_SHA'];
  if (Platform.environment['GITHUB_ACTIONS'] != 'true' ||
      Platform.environment['GITHUB_REPOSITORY'] != _repository ||
      Platform.environment['GITHUB_REF'] != 'refs/heads/$_branch' ||
      source == null || !RegExp(r'^[0-9a-f]{40}$').hasMatch(source)) {
    throw StateError('Releases require a $_branch push in $_repository');
  }
  return source;
}

// Signing -------------------------------------------------------------------

Directory get _signingDirectory => Directory('${_env('RUNNER_TEMP')}/spotify-signing');

void _signingSetup() {
  final identity = _env('MACOS_SIGNING_IDENTITY');
  final team = _env('MACOS_TEAM_ID');
  if (!identity.startsWith('Developer ID Application: ') || !identity.endsWith(' ($team)')) {
    throw StateError('Developer ID signing identity and team do not match');
  }
  final directory = _signingDirectory;
  if (directory.existsSync()) throw StateError('Stale CI signing directory exists');
  _run('/bin/mkdir', ['-m', '700', directory.path]);
  final keychain = '${directory.path}/release.keychain-db';
  final certificate = File('${directory.path}/certificate.p12');
  final notaryKey = File('${directory.path}/notary.p8');
  final previous = RegExp(r'"([^"]+)"').allMatches(_run('/usr/bin/security', ['list-keychains', '-d', 'user']))
    .map((match) => match.group(1)!).toList();
  File('${directory.path}/keychains.json').writeAsStringSync(jsonEncode(previous));
  certificate.writeAsBytesSync(base64Decode(_env('MACOS_CERTIFICATE_P12_BASE64')));
  notaryKey.writeAsBytesSync(base64Decode(_env('MACOS_NOTARY_KEY_P8_BASE64')));
  _run('/bin/chmod', ['600', certificate.path, notaryKey.path]);
  final random = Random.secure();
  final password = base64UrlEncode(List<int>.generate(32, (_) => random.nextInt(256)));
  _run('/usr/bin/security', ['create-keychain', '-p', password, keychain]);
  _run('/usr/bin/security', ['set-keychain-settings', '-lut', '21600', keychain]);
  _run('/usr/bin/security', ['unlock-keychain', '-p', password, keychain]);
  _run('/usr/bin/security', ['import', certificate.path, '-k', keychain,
    '-P', _env('MACOS_CERTIFICATE_PASSWORD'), '-T', '/usr/bin/codesign', '-T', '/usr/bin/security']);
  _run('/usr/bin/security', ['set-key-partition-list', '-S', 'apple-tool:,apple:,codesign:', '-s', '-k', password, keychain]);
  _run('/usr/bin/security', ['list-keychains', '-d', 'user', '-s', keychain, ...previous]);
  if (!_run('/usr/bin/security', ['find-identity', '-v', '-p', 'codesigning', keychain]).contains('"$identity"')) {
    throw StateError('Developer ID identity missing from the imported certificate');
  }
  File(_env('GITHUB_ENV')).writeAsStringSync([
    'SPOTIFY_CODESIGN_IDENTITY=$identity',
    'SPOTIFY_APPLE_TEAM_ID=$team',
    'SPOTIFY_NOTARY_KEY_PATH=${notaryKey.path}',
    'SPOTIFY_NOTARY_KEY_ID=${_env('MACOS_NOTARY_KEY_ID')}',
    'SPOTIFY_NOTARY_ISSUER_ID=${_env('MACOS_NOTARY_ISSUER_ID')}',
    '',
  ].join('\n'), mode: FileMode.append);
  stdout.writeln('Imported Developer ID signing credentials into an ephemeral keychain.');
}

void _signingCleanup() {
  final directory = _signingDirectory;
  final previous = File('${directory.path}/keychains.json');
  if (previous.existsSync()) {
    final names = (jsonDecode(previous.readAsStringSync()) as List).cast<String>();
    _run('/usr/bin/security', ['list-keychains', '-d', 'user', '-s', ...names]);
  }
  final keychain = File('${directory.path}/release.keychain-db');
  if (keychain.existsSync()) _run('/usr/bin/security', ['delete-keychain', keychain.path]);
  if (directory.existsSync()) directory.deleteSync(recursive: true);
  stdout.writeln('Removed ephemeral signing credentials.');
}

// package -------------------------------------------------------------------

String get _dmgName {
  final version = _version(File('$_root/$_manifest').readAsStringSync());
  return 'spotify_flutter-${_tag(version).substring(1)}-macos-arm64.dmg';
}

void _package() {
  final identity = _env('SPOTIFY_CODESIGN_IDENTITY');
  final team = _env('SPOTIFY_APPLE_TEAM_ID');
  final notary = ['--key', _env('SPOTIFY_NOTARY_KEY_PATH'), '--key-id', _env('SPOTIFY_NOTARY_KEY_ID'),
    '--issuer', _env('SPOTIFY_NOTARY_ISSUER_ID')];
  final output = '$_root/$_products';
  final app = '$output/$_app';
  _verifySignature(app, team);
  final temporary = Directory(output).createTempSync('.package-');
  try {
    final zip = '${temporary.path}/app.zip';
    _run('/usr/bin/ditto', ['-c', '-k', '--keepParent', app, zip], echo: true);
    _notarize(zip, notary);
    _run('/usr/bin/xcrun', ['stapler', 'staple', app], echo: true);
    _run('/usr/sbin/spctl', ['--assess', '--type', 'execute', '--verbose=2', app], echo: true);
    _verifySignature(app, team);

    final image = Directory('${temporary.path}/image')..createSync();
    _run('/usr/bin/ditto', [app, '${image.path}/$_app']);
    Link('${image.path}/Applications').createSync('/Applications');
    final dmg = '${temporary.path}/$_dmgName';
    _run('/usr/bin/hdiutil', ['create', '-volname', 'Spotify Flutter', '-srcfolder', image.path,
      '-ov', '-format', 'UDZO', dmg], echo: true);
    _run('/usr/bin/codesign', ['--force', '--sign', identity, '--timestamp', dmg], echo: true);
    _notarize(dmg, notary);
    _run('/usr/bin/xcrun', ['stapler', 'staple', dmg], echo: true);
    _run('/usr/sbin/spctl', ['--assess', '--type', 'open', '--context', 'context:primary-signature',
      '--verbose=2', dmg], echo: true);
    File(dmg).renameSync('$output/$_dmgName');
    stdout.writeln('Packaged $output/$_dmgName');
  } finally {
    temporary.deleteSync(recursive: true);
  }
}

void _notarize(String path, List<String> credentials) {
  final result = jsonDecode(_run('/usr/bin/xcrun', ['notarytool', 'submit', path, ...credentials,
    '--wait', '--output-format', 'json']));
  if (result is Map && result['status'] == 'Accepted') {
    stdout.writeln('Apple notarization accepted ${path.split('/').last}.');
    return;
  }
  if (result is Map && result['id'] is String) {
    stderr.writeln(_run('/usr/bin/xcrun', ['notarytool', 'log', result['id'] as String, ...credentials]));
  }
  throw StateError('Apple notarization rejected ${path.split('/').last}: $result');
}

void _verifySignature(String app, String team) {
  _run('/usr/bin/codesign', ['--verify', '--deep', '--strict', '--verbose=2', app]);
  final metadata = Process.runSync('/usr/bin/codesign', ['-dv', '--verbose=4', app]).stderr as String;
  if (!metadata.contains('Identifier=$_bundleId\n') || !metadata.contains('TeamIdentifier=$team\n') ||
      !metadata.contains('Authority=Developer ID Application: ') || !metadata.contains('Timestamp=') ||
      !RegExp(r'^CodeDirectory .*flags=.*\bruntime\b', multiLine: true).hasMatch(metadata)) {
    throw StateError('Release requires Developer ID signing, hardened runtime and a secure timestamp:\n$metadata');
  }
  if (_run('/usr/bin/codesign', ['-d', '--entitlements', '-', '--xml', app]).contains('get-task-allow')) {
    throw StateError('Release must not carry the debugging entitlement');
  }
}

// publish -------------------------------------------------------------------

void _publish() {
  final source = _requireGitHubPush();
  final tag = _env('RELEASE_TAG');
  final version = _tagVersion(tag);
  if (version == null || _compare(version, _version(File('$_root/$_manifest').readAsStringSync())) != 0) {
    throw StateError('$tag does not match the checked-out $_manifest');
  }
  final head = _git(['rev-parse', 'HEAD']).trim();
  if (_git(['rev-parse', '$tag^{commit}']).trim() != head || _git(['rev-parse', 'HEAD^']).trim() != source) {
    throw StateError('Checkout is not the release commit of $tag for $source');
  }
  final dmg = '$_root/$_products/$_dmgName';
  if (!File(dmg).existsSync()) throw StateError('Notarized DMG is missing: $dmg');
  final existing = Process.runSync('gh', ['release', 'view', tag, '--json', 'assets']);
  if (existing.exitCode == 0) {
    final assets = (jsonDecode(existing.stdout as String) as Map)['assets'] as List;
    if (assets.any((asset) => asset is Map && asset['name'] == _dmgName)) {
      stdout.writeln('Release $tag already has $_dmgName.');
    } else {
      _run('gh', ['release', 'upload', tag, dmg], echo: true);
    }
    return;
  }
  _run('gh', ['release', 'create', tag, dmg, '--verify-tag', '--latest', '--title', tag,
    '--notes', 'Developer ID signed and notarized macOS build for Apple silicon.\n\nSource commit: $source'], echo: true);
}

// Helpers -------------------------------------------------------------------

String _env(String name) {
  final value = Platform.environment[name];
  if (value == null || value.isEmpty) throw StateError('Missing environment variable $name');
  return value;
}

String _git(List<String> arguments, {Map<String, String>? environment}) =>
  _run('git', arguments, environment: environment);

String _run(String command, List<String> arguments, {Map<String, String>? environment, bool echo = false}) {
  final result = Process.runSync(command, arguments, workingDirectory: _root, environment: environment);
  if (echo) {
    stdout.write(result.stdout);
    stderr.write(result.stderr);
  }
  if (result.exitCode != 0) {
    // Arguments are omitted: some carry keychain or certificate passwords.
    throw StateError('$command ${arguments.first} failed (exit ${result.exitCode}): ${result.stderr}'.trim());
  }
  return result.stdout as String;
}
