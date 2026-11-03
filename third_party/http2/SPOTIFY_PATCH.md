# Pinned public HTTP/2 transport

This is the public Dart `http2`3.1.0 library, reused under its retained BSD
license. `UPSTREAM.json` pins the pub.dev archive SHA-256 and every upstream
file digest. No Chromium or other standard-library binary was decompiled.

The local patch exposes optional client receive settings which the upstream
API cannot supply: HPACK table limit, header-list limit and connection window.
It writes configured SETTINGS in identifier order and sends the initial
connection WINDOW_UPDATE through the existing standard frame writer. HPACK's
decoder limit and the local connection/stream windows agree with the advertised
values. A stream created before the peer's ACK already has the advertised
receive window; that ACK must not spuriously enlarge the opposite send window.
Unset options retain the upstream default wire profile.

The optional `HeadersPriority` argument on `makeRequest` carries the standard
RFC7540 dependency, semantic weight1..256 and exclusive bit through the
existing queues. The frame writer sets HEADERS flag0x20 and writes the five
priority bytes before the HPACK fragment; the wire weight is semantic weight
minus1. The existing six-byte fixed-payload reservation also covers this
five-byte prefix when fragmenting. CONTINUATION frames have no priority prefix.
This generic extension changes neither HPACK nor local write scheduling. The
application owns the dependency policy and stream lifetime in Dart.

The app's `NativeCefHttp2Pool` implementation supplies both pool owners with the profile independently
observed across94 original sessions: table65536, push0, stream6291456,
header-list262144, connection15728640. The pool owners remain separate; both
use this configured implementation. The original authority and event anchors
are in `reverse-engineering/evidence/native-http2-initial-settings.json` at the repository root.

The focused existing outgoing check first failed with the upstream default
SETTINGS `[2,0]`, then passed with all four original settings in order and the
original initial connection-window delta15663105 before HEADERS. The standard
H2 state machine, framing, pooling and HPACK implementation remain in this
library. HPACK output bytes, later flow-control thresholds, scheduling and TLS
fingerprints are separate from this initial SETTINGS/window proof.

The original priority authority is
`reverse-engineering/evidence/native-http2-priority.json`:357 selected default HEADERS all
include priority metadata, with native weight110 and renderer Pathfinder220,
always exclusive. Independently compiled, unchanged public creation,
destruction and weight routines supply the expected dependency trace. The
existing native outgoing owner holds real response streams open while later
ones complete; parents0/1/1/0 on streams1/3/5/7 prove that the sender uses live
dependencies. Both native/renderer owners first failed with missing metadata.

`SPOTIFY.patch` records the exact diff from the pinned archive for the seven
changed upstream files. The application uses this package through a path
dependency, without modifying the global pub cache.
