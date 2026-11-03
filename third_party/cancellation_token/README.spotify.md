# Local cancellation_token repair

The app uses the published `cancellation_token` 2.0.1 implementation and public
API. `upstream.json` pins the pub archive identity and hashes the unmodified
files. MIT and Dart SDK notices remain in `LICENSE`.

The local change is confined to `MergedCancellationToken.onCancel` and its
delivery guard. Resource cleanup can cancel a second parent while a merged
token is already notifying its attached operations. Upstream iterates the live
list, allowing reentrant notification to clear it, repeat callbacks and raise
`ConcurrentModificationError` before remaining cleanup executes. This occurred
in the app's actual rapid-selection cancellation path.

Notification now snapshots and clears that list before callbacks, and delivery
is idempotent. Lazy parent status, exception selection before delivery, public
types and normal cancellation behavior remain upstream-owned. There is no
second application cancellation API.

The separate application changes observe cancellation-triggered stream/decoder
close futures immediately and join the same futures at their owning cleanup
boundaries. They do not treat observing an error as stopping the underlying IO.
