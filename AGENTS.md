# Spotify in Flutter Rules

## Repo

- never use python, use dart instead
- `moonx dev` is likely already running. hot reload and probe it to verify changes

## Release debugging and logs

- **Always check the app's existing logs first when investigating release playback, networking, or licensing failures.** Release HTTP diagnostics work without a Dart VM service; use these logs, macOS diagnostics, and native debugger attachment as needed.
- The log root is **`~/Library/Containers/dev.meoyawn.spotifyFlutter/Data/Library/Logs/spotify_flutter`**. The installed release writes `release/http.jsonl`; debug writes `debug/http.jsonl`; profile writes `profile/http.jsonl`. Read the directory for the build actually running.
- Inspect the current file and relevant rotated archives (`http.jsonl.1` through `http.jsonl.3`, newest to oldest) before a necessary restart. Correlate entries by `pid` and `request_id`; inspect method, redacted host/path, HTTP status, `headers_ms`, Retry-After, and transport errors. A request without a response may still be pending or waiting for a transport deadline.
- Preserve separate build-mode destinations and bounded rotation: at most four files of 1 MiB each, **4 MiB per mode across restarts**. Keep the asynchronous write queue bounded. Never add credentials, request/response bodies, signed URL queries, or opaque account/device/media IDs to these logs.

## Reverse engineering

- Decompile Spotify's proprietary code only. Reuse standard libraries and their public source/docs, including Chromium, FFmpeg, TLS/QUIC, protobuf, and cryptography. Do not decompile Chromium.
- Verify protocol and request behavior against independently executed original routines or original captures before treating the Dart implementation as compatible. Record source identity, substituted standard primitives and the exact scope proved. Expected bytes must not come from the Dart implementation being checked.

## Account support

- Spotify Free accounts are the current target. Recover their session, entitlements and playback restrictions from the original client.
- Prioritize Free-account sign-in, browsing and live streaming from Spotify servers. Local filesystem music playback and offline/download features are out of scope. Transient media buffering required for streaming is separate from a local music library. Do not infer Premium permissions.
- Librespot may be referenced, reused, or forked. Its upstream Premium-only behavior does not satisfy the Free-account requirement.
- Preserve the HTTP access-token provider selected by the actual authentication path. Restoring this app's saved Accounts grant restores its Accounts provider without a token seed. An AP reusable credential restores AP authentication independently; its presence alone does not establish the original early Login5 cache/result path or authorize switching the session's HTTP provider. Keep native HTTP, renderer and push consumers on the same selected provider. See [the original execution and live comparison](reverse-engineering/evidence/native-license-session-comparison.json).

## Advertising

- Never display or play advertisements in Flutter: no audio/video creatives, banners, Home takeovers, sponsored cards, advertiser artwork, click targets or empty reserved ad space. Exclude advertisements from the audible queue and media output, including prefetch and restored playback.
- Ad lifecycle imitation is inert local protocol bookkeeping. Follow SpotX's approach of suppressing unnecessary ad subscriptions/requests and presentation at their owners. Never download creative assets, run a silent decoder, wait through simulated playback, poll ad state or send fake impressions/completions. Enable a real ad-control exchange only when independent original evidence demonstrates it is needed to keep Free streaming playable; verify its exact outgoing contract first. Preserve only incoming metadata needed for that bookkeeping, without exposing it to widgets or OS media controls.
- Use [SpotX-Official/SpotX](https://github.com/SpotX-Official/SpotX) as the suppression authority. The inspected reference is commit [06f7fa2eac989c84613b2e0efc9b18acaf97f6cb](https://github.com/SpotX-Official/SpotX/commit/06f7fa2eac989c84613b2e0efc9b18acaf97f6cb), especially [patches/patches.json](https://github.com/SpotX-Official/SpotX/blob/06f7fa2eac989c84613b2e0efc9b18acaf97f6cb/patches/patches.json): `free.emptyblock`, `VariousJs.banner_home`, `free.audioads` and `others.binary.block_slots*`. Respect their recorded version ranges; the old Windows byte patches alone do not prove compatibility with this macOS build. The optional [sectionBlock.js](https://github.com/SpotX-Official/SpotX/blob/06f7fa2eac989c84613b2e0efc9b18acaf97f6cb/js-helper/sectionBlock.js) operates after the original content fetch; distinguish paid placements from ordinary music shelves.
- Port suppression into the Dart owners. Do not run the SpotX installer or patch the installed original used for protocol evidence. Keep the actual Free product state, authentication, licensing and integrity inputs intact; SpotX's broader `VariousJs.product_state` Premium overrides are not server-granted entitlements.

## Product and efficiency goal

- Deliver an ad-free Free-account streaming app that stays playable, responsive and unobtrusive with the minimum practical network traffic, CPU, memory and background work. Use SpotX's suppression approach as the reference for removing unnecessary advertising work.
- Follow the current priority order in [the remaining-work backlog](docs/remaining-work.md): resolve playback admission failures and verify live cold/cached selections before adding further UI features. Use REA and independently executed original routines/captures to distinguish session, request, cache and transport causes.
- Preserve real native playback reporting for the existing Last.fm Spotify Scrobbling connection. Report actual played music and state, exclude ads and abandoned loads, and coalesce updates without per-tick traffic. Do not add a competing direct Last.fm submission path or copied application keys. See [the original playback-reporting evidence](reverse-engineering/evidence/native-connect-player-projection.json).
- Avoid speculative traffic, duplicate metadata/media/license requests, polling and repeated decoding. Share in-flight work, honor actual cache/expiry state, cancel abandoned work and bound caches/queues. Prefetch only when it measurably improves the next audible transition without competing with the current selection.
- Bound the whole app-owned transient streaming footprint across restarts, including decoded PCM, encrypted media and abandoned/incomplete files. Recover capacity, retention and orphan cleanup from the original client with REA; protect active readers/writers and keep their cleanup tied to real ownership. A per-process cache limit alone does not establish a bounded cache directory. Preserve ongoing user playback while changing cache management.
- Keep work proportional to visible content and actual playback needs. Stop UI clocks/listeners when their views are not observing them; do not rebuild whole panels for position ticks. Fetch additional pages on demand. Do not scan unrelated collections to satisfy navigation.
- Preserve the authentic session, account restrictions and verified protocol behavior needed for playback. Prefer measured reductions in request count, bytes and CPU/latency; do not add synthetic handshakes, background telemetry or broad test/benchmark suites to pursue this goal.
