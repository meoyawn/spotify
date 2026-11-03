# Remaining work

This is the single current backlog: unfinished implementation and missing
original-client evidence. Updated 30 October 2026 from the current source and
reported behavior. Original-client evidence lives in
[reverse-engineering/](../reverse-engineering/).

## Highest priority: reliable, fast licenses

Finish this before further Library, Home or other UI features. Use the REA
workflow to recover and compare the original client's actual license admission,
session, cache and request behavior. A locally matching request fixture is not
completion while a real Free-account selection remains stuck at0:00.

The former grant exposed429 after an initially successful selection and after
renewal over both H2 and H3; its server admission failure remains unknown.
The bounded Accounts-provider correction does not close this priority.
[Session comparison](../reverse-engineering/evidence/native-license-session-comparison.json)
and [playback reporting](../reverse-engineering/evidence/native-connect-player-projection.json)
provide bounded observations. They do not explain the earlier 429 failures or
establish sustained reliability across sessions.

| Area | Implementation still needed | Reverse engineering or verification still needed |
| --- | --- | --- |
| **License reliability and latency** | Finish remaining source preparation and cancellation gaps; avoid restarting identical owned work, remove measured avoidable cold-start waits and keep loading/current-track state correct. Preserve the actual session's token provider and avoid unnecessary or competing license/metadata/media requests. | Extend the bounded [process-restoration, natural-renewal and full-track transition observations](../reverse-engineering/evidence/native-license-session-comparison.json) across longer queues and independently restored sessions; resolve the former grant's unexplained429 failures. Bind the recovered cache identity, capacity, eviction and timestamp behavior to persistent source ownership; recover remaining next-song admission policies. Do not substitute Premium rights, fake acknowledgements or speculative retries. Owners: [desktop runtime](../lib/app/native_desktop_runtime.dart), [license exchange](../lib/playback/native_playplay_license.dart), [audio engine](../lib/playback/dart_audio_engine.dart). |

## User-facing features

| Area | Implementation still needed | Reverse engineering or verification still needed |
| --- | --- | --- |
| **Complete Library** | Folder mutations, remaining media filters/sorts, native pins/reordering and applicable mutations. | Extend [fifty-context Recents](../reverse-engineering/fixtures/native-recent-contexts.json) to older history and original live invalidation. Verify live folder hierarchy, original malformed-marker recovery/ownership grouping and pin/mutation bindings. Owners: [native Library join](../lib/library/native_library_repository.dart), [Library controller](../lib/library/controller.dart). |
| **Search refinements** | Browse all at an empty query, original combined podcast/show category coordinator and remaining specialized result decorations/destinations. | Recover Browse all and combined/category visibility bindings; establish session experiment selection before optional list/Instant Mix/concert/video presentation. Full results, category paging and recent-history mutations now use original-executed outgoing contracts; live history-write acceptance remains unverified. Owners: [search repository](../lib/search/repository.dart), [results view](../lib/search/results_view.dart). |
| **Home** | Remaining unsupported shelves/cards, Recently Played presentation and specialized hub destinations. | Recover native Recent Contexts and the remaining grid/spotlight/video visibility and card decoration policies. Ordinary Home “Show all”, genre pages and Browse shelf paging now use original-executed requests; finish the remaining destination variants. Owners: [Home models](../lib/home/models.dart), [destination repository](../lib/home/destinations_repository.dart), [destination view](../lib/home/destinations_view.dart). |
| **Artwork reliability** | Restore remaining public artwork that fails on `i.scdn.co`, including Browse collections without a native-map alternative. | Existing debug logs and a separate TLS connection reproduce handshake timeouts. The current 49-collection map has no `ab67fb82` Browse collection; do not invent replacement hosts. Recover original resolution/transport behavior for these sources. Pickasso Release Radar and current Daily Mix path admission is repaired and live-verified. Owners: [artwork loading](../lib/app/native_desktop_runtime.dart), [public image client](../lib/protocol/native_image_client.dart). |
| **Queue** | Enable Queue panel/editing. | Recover original queue-editing and ordering behavior, including Free-account restrictions. Ordinary bottom-bar controls are recovered and bound in the [playback-bar evidence](../reverse-engineering/evidence/native-renderer-playback-bar.json). Owners: [playback bar](../lib/app/playback_bar.dart), [player controller](../lib/playback/controller.dart). |
| **Connect / devices** | Enable device selection and applicable playback/transfer controls. | Finish device discovery, session ownership, transfer messages and account restrictions. The disabled device button is not a complete Connect implementation. Owners: [playback bar](../lib/app/playback_bar.dart), [desktop runtime](../lib/app/native_desktop_runtime.dart). |
| **Playlist / album interactions** | Real sort choices, context menus, playlist editing/reordering, description links and complete detail decorations. | Trace menu/mutation contracts and missing dynamic decoration policies. Owners: [entity view](../lib/entities/view.dart), [playlist repository](../lib/entities/native_playlist_repository.dart). |
| **Now Playing interactions** | Additional original preview/shelf content. | Recover remaining content contracts and visibility rules. Owner: [Now Playing panel](../lib/app/now_playing_panel.dart). |

Resume Library folders/mutations and Home destinations after license reliability
and latency are verified. Remove completed rows
instead of turning this into an achievement log.

## HTTP and playback

| Area | Implementation still needed | Reverse engineering or verification still needed |
| --- | --- | --- |
| **Systemic HTTP fidelity** | Replace regex Alt-Svc parsing/cache updates; finish transport integration for remaining original request families and documented gaps in priority changes, connection state and request/session ownership. | Independently execute original parser/cache policy and compare each newly admitted request family with original captures/execution. Complete H2/H3 selection, compression/framing and TLS/QUIC fingerprint parity is not established by matching decoded headers. Owners: [protocol policy](../lib/protocol/native_http_protocol_policy.dart), [transports](../lib/transport/), [comparison notes](../reverse-engineering/evidence/native-http-protocol-inventory.json). |
| **Cold / cached song startup** | Remove measured avoidable waits so fresh and cached selections approach original click-to-audio latency; keep loading/current-track UI synchronized. Avoid rebuilding the complete collection membership snapshot on every process restoration. | Measure comparable cold/warm conditions. Recover original persisted/delta collection synchronization before replacing the45-page restored-startup sweep; preserve complete saved-state correctness. Finish original prefetch and key/license reuse evidence; extend the recovered [selected-file/cache/storage identity](../reverse-engineering/evidence/native-stream-cache-source.json) to complete response admission, cross-player sharing and existing-index reuse. [Metadata freshness](../reverse-engineering/evidence/native-audio-files-cache.json) is not license expiry. Owners: [audio engine](../lib/playback/dart_audio_engine.dart), [media source](../lib/playback/spotify_media_source.dart), [collection snapshot](../lib/library/native_collection_read_client.dart). |
| **Transient streaming storage** | Finish original capacity/retention integration and active-PCM storage without deleting active readers/writers or allowing abandoned buffers to accumulate. | Extend [cache reconciliation evidence](../reverse-engineering/evidence/native-stream-cache-reconciliation.json) to reclamation of owned-session directories across restarts. The actual [filesystem-provider/capacity/prune-owner chain](../reverse-engineering/evidence/native-stream-cache-volume.json) now executes independently. Finish original timestamp and protection execution evidence, then recover live configuration/override assignments, disk-observation invalidation and persistent index reopening. The [body execution](../reverse-engineering/evidence/native-stream-cache-body.json) proves unchanged bytes at the cache write boundary; physical file/index framing remains separate. Application encrypted-fill budgets and cleanup do not establish complete original cache-policy parity. |
| **Cancellation completion** | Inspect remaining initialization and queued platform work for missing `cancellation_token` ownership. AP/browser sessions, image setup, media requests, file/output setup and queued session saves now propagate tokens. Cancel actual owned work on supersession/disposal; retain independently needed shared work. | Continue the [ownership migration](../reverse-engineering/evidence/native-playplay-terminal-policy.json), including live rapid-selection acceptance of the merged-token/stream-cleanup repair, and verify changed outgoing contracts against original execution/captures. Do not replace real aborts with abandoned Futures or add general lifecycle/UI suites. |
| **Sustained playback / performance** | Resolve reproducible remaining stalls, transition-state delays, memory growth and loaded-playlist scroll/sidebar/window-resize jank. | Recheck long playback and loaded-content interactions with traces. Earlier fixes and individual transitions do not establish stable memory, latency or gapless behavior across sessions. Owners: [audio engine](../lib/playback/dart_audio_engine.dart), [shell](../lib/app/shell.dart), [entity view](../lib/entities/view.dart). |

Target: Spotify Free server streaming. Offline/downloads and local filesystem
music remain outside the current scope.

## Why both quiche and nghttp3?

They do different jobs in the same process:

| Library | Role in this app |
| --- | --- |
| **Cloudflare quiche** | QUIC and TLS: encrypted UDP connections, QUIC streams, acknowledgements and flow control. |
| **nghttp3** | HTTP/3 and QPACK: HTTP frames, compressed headers, dynamic header tables and HTTP priority control, over quiche's streams. |

The pinned quiche **0.30.0** has its own HTTP/3 implementation, but its QPACK
decoder does not support dynamic tables. Configuration setters alone cannot
provide the original client's advertised 64 KiB dynamic table and 100 blocked
streams. nghttp3 supplies that standard codec behavior. This app uses quiche's
QUIC layer rather than stacking two HTTP/3 implementations.

Dart owns Spotify requests, credentials, session decisions, queues and player
state. Both libraries run in process; neither is a separate player. Removing
nghttp3 requires a replacement with verified dynamic QPACK support. Source pins
and original settings are in the [transport evidence](../reverse-engineering/evidence/native-http3-initial-settings.json)
and [native codec manifest](../native/nghttp3/upstream.json).
