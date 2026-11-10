# Spotify Flutter

Flutter desktop reconstruction of Spotify macOS 1.3.6.1921, targeting Spotify
Free sign-in, browsing and server streaming. Spotify/player/session logic lives
in Dart; standard native libraries supply transport, cryptography and audio.

**[Remaining work](docs/remaining-work.md)** is the single current backlog,
including missing implementation, missing reverse engineering and why HTTP/3
uses both quiche and nghttp3.

```text
lib/                   Flutter/Dart application implementation
assets/                Runtime fonts, icons and application data
macos/                 macOS runner and platform integration
native/                Standard native dependencies and build glue
proto/                 Readable schemas and code-generation manifests
third_party/           Pinned standard Dart dependencies
test/                  Protocol verification code
tools/                 Build, generation, launch and verification entry points
reverse-engineering/   Original-client evidence, protocol fixtures and descriptors
docs/remaining-work.md The only document in docs/: unfinished work
```

Original-client evidence and expected protocol data live under
[reverse-engineering/](reverse-engineering/README.md). Private captures,
credentials and caches belong in ignored `.local/` storage. Build tools and
local protocol peers share the locked environment at `tools/oracles/`.

Prepare and run development:

```sh
flutter pub get
uv sync --project tools/oracles --locked
uv run --project tools/oracles --locked python tools/generate_protocols.py
uv run --project tools/oracles --locked python tools/generate_playback_protocols.py
moon run native
moon run dev
```

`moon run dev` runs Flutter in the project directory with hot reload: press `r`
to reload, `R` to restart, or `q` to quit. It reports an already-running app or
Flutter run and exits without launching another instance. Extra Flutter arguments
can follow `--`, for example `moon run dev -- --no-pub`. Keep one desktop app
process and the debug badge visible. Never run `dart format`.

Paste an `open.spotify.com`, `play.spotify.com` or `spotify:` link into Search
and press Enter to open its page. The macOS runner also receives `spotify:`
URLs and HTTP links explicitly sent to it, for example
`open -a spotify_flutter 'https://open.spotify.com/album/4uLU6hMCjMI75M1A2tKUQC'`.
Rebuild the runner for native link delivery. This registration leaves browser
defaults unchanged; ordinary HTTPS clicks still use the browser unless forwarded
to the app. Opening a page does not start playback. Original-client evidence is
recorded in [native-open-links.json](reverse-engineering/evidence/native-open-links.json).

Original-backed outgoing HTTP verification:

```sh
dart run tools/verify_http_protocols.dart
```

This compares outgoing requests with retained original evidence using
independent local peers, without contacting a Spotify account.

Build with `moonx release`; build and reinstall with `moonx release-reinstall`.
Reinstall stops the installed release if it is running and confirms its process
exited before replacing the app. It never launches the release; an active debug
app is left running. `moonx reinstall-release` remains an alias.
Native dependency versions and source hashes are pinned under `native/`.

Moon caches each native library using its builder, source manifest, patches,
C/Rust inputs and locked Python configuration. Flutter edits leave these caches
valid. The FFmpeg cache includes the static libraries and public headers needed
to relink streaming without its original build tree. After upgrading the system
compiler, SDK, Cargo/Rust or CMake, refresh with `moon run native --force`;
these tasks use the system toolchain.

Bounded HTTP diagnostics live under
`~/Library/Containers/dev.meoyawn.spotifyFlutter/Data/Library/Logs/spotify_flutter/`,
in separate `debug/`, `profile/` and `release/` directories. Each retains at most
four 1 MiB files. Logs omit credentials, bodies, queries and opaque IDs.
