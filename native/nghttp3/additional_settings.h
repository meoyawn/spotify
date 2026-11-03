// Local extension to the pinned standard codec. Configure at most 8 extra
// settings before binding the control stream. Entries are copied, checked for
// duplicates/known or prohibited IDs, and serialized in numeric-ID order with
// the standard settings. An optional unknown control frame (at most 256 payload
// bytes, copied) follows SETTINGS. Both use the standard codec's frame writer.
// No app, session or random-generation policy runs here.
#pragma once
#include "../../.local/vendor/nghttp3/lib/includes/nghttp3/nghttp3.h"
#ifdef __cplusplus
extern "C" {
#endif
NGHTTP3_EXTERN int nghttp3_conn_set_additional_settings(nghttp3_conn *conn,
    const uint64_t *ids, const uint64_t *values, size_t count);
NGHTTP3_EXTERN int nghttp3_conn_set_additional_control_frame(nghttp3_conn *conn,
    uint64_t type, const uint8_t *payload, size_t length);
#ifdef __cplusplus
}
#endif
