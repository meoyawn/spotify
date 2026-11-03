// Local, read-only transport primitive; original quiche C ABI stays unchanged.
// The implementation returns the actual highest contiguous peer ACK offset.
// No request, HTTP, playback or session decisions run in this native helper.
#pragma once
#include "../../.local/vendor/quiche/quiche/include/quiche.h"

#ifdef __cplusplus
extern "C" {
#endif
bool quiche_conn_stream_acked_offset(const quiche_conn *conn, uint64_t stream_id,
                                     uint64_t *offset);
#ifdef __cplusplus
}
#endif
