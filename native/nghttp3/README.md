# nghttp3 standard primitive

This directory pins [nghttp3 v1.18.0](https://github.com/ngtcp2/nghttp3/releases/tag/v1.18.0),
commit `dbfc24286138cb0b6490160e7ca87fe1ce6722a0`. It provides standard HTTP/3 and
QPACK, including dynamic tables, over a caller-owned QUIC transport. It does not
contain Spotify request, session, player or queue logic.

`upstream.json` records the Git commit, SHA-256 of the complete `git archive`
source, public header and licenses. The embedded standard structured-field
parser, sfparse, is pinned and checked independently. The build applies only
the declared `additional-settings.patch`, with exact preimage/result hashes;
it refuses unrelated tracked changes. The public upstream header stays intact.

`additional_settings.h` exposes two generic additions before control-stream
binding: at most 8 extra unknown SETTINGS entries and one opaque control frame
with at most 256 copied payload bytes. IDs/values are range checked; duplicate,
known or forbidden IDs are rejected. The standard codec sorts the complete
settings list by numeric ID and writes the extra frame immediately afterward
using its existing frame-header/vector writer. Native state owns the copied
payload through teardown. No private struct layout crosses FFI.

Dart supplies the original transport's GREASE recipe once per HTTP/3 session.
The C extension supplies no random, Spotify, request or session policy. Original
SETTINGS captures and pinned public source establish separate scopes in
[`native-http3-grease.json`](../../reverse-engineering/evidence/native-http3-grease.json).

```sh
uv run --project tools/oracles --locked python tools/build_nghttp3.py
uv run --project tools/oracles --locked python tools/generate_nghttp3_bindings.py
```

The build targets only the C shared library, with tests, examples and the static
library disabled. Source lives under `.local/vendor/nghttp3`; CMake output lives
under `.local/native-build/nghttp3`. The signed macOS arm64 result is staged at
`.local/native/libnghttp3.dylib` with install identity
`@rpath/libnghttp3.dylib`. Deployment target is macOS11.0. Its sole dynamic
dependency is Apple's system `libSystem.B.dylib`; sfparse is compiled into it.
`.local/native/nghttp3-build.json` records compiler, options, generated version
header and the built library's identity.

The generated public C bindings live in `lib/transport/nghttp3/bindings.dart`.
Generation uses the existing pinned FFIgen toolchain with `--no-format` and
checks the source header identity first. Both current versioned ABI selectors
are4 (`NGHTTP3_CALLBACKS_VERSION` and `NGHTTP3_SETTINGS_VERSION`). The public
header's convenience constructor/default macros map to the exported
`nghttp3_conn_client_new_versioned` and `nghttp3_settings_default_versioned`
functions. Stable1.18 has no `nghttp3_conn_is_remote_qpack_encoder_stream` API.

Application packaging must copy `libnghttp3.dylib` to the app's Frameworks
directory and retain both `LICENSE.nghttp3` and `LICENSE.nghttp3-sfparse`.
This primitive build does not change app packaging, select transport settings,
launch a desktop instance, or claim Spotify protocol compatibility. The Dart
transport owner must connect stream delivery, flow control, actual acknowledged
send offsets, cancellation and lifetime to this standard API; independently
observed outgoing protocol checks own that integration's correctness.
