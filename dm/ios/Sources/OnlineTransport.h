#pragma once
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// Polling C ABI for a future verified game-engine adapter. Never call release
// concurrently with another operation; after release the handle is invalid.
// Open connects asynchronously. State: 1 connecting, 2 ready, 3 EOF, 4 closed,
// 5 failed. Error returns the native error code without credentials or payload.
void *dm_online_tcp_open(const char *host, uint16_t port, uint32_t timeout_ms);
int32_t dm_online_tcp_state(void *handle);
int32_t dm_online_tcp_error(void *handle);
// Send: 0 = queued locally, not peer acknowledgement. Read: >0 = byte count.
// Negative results: -1 retry later, -2 closed, -3 failed, -4 invalid arguments,
// -5 size limit. Max send/read chunk 65536, total queued bytes 262144.
int32_t dm_online_tcp_send(void *handle, const void *bytes, size_t length);
int32_t dm_online_tcp_read(void *handle, void *bytes, size_t capacity);
void dm_online_tcp_release(void *handle);
#ifdef __cplusplus
}
#endif
