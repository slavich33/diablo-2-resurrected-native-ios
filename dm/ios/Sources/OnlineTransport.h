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
// Port is deliberately 32-bit at the host boundary; valid range is 1..65535.
void *dm_online_tcp_open(const char *host, uint32_t port, uint32_t timeout_ms);
int32_t dm_online_tcp_state(void *handle);
int32_t dm_online_tcp_error(void *handle);
// Send: 0 = queued locally, not peer acknowledgement. Read: >0 = byte count.
// Negative results: -1 retry later, -2 closed, -3 failed, -4 invalid arguments,
// -5 size limit. Max send/read chunk 65536, total queued bytes 262144.
int32_t dm_online_tcp_send(void *handle, const void *bytes, size_t length);
int32_t dm_online_tcp_read(void *handle, void *bytes, size_t capacity);
void dm_online_tcp_release(void *handle);

// Incremental game-packet layer AFTER transport framing/decompression.
// These handles are caller-serialized, non-reentrant; keep callback/context
// alive until release. The callback runs on the polling caller's thread.
// Return packet length (1..65536), 0 = need more header, -1 = unsupported.
// Header prefix is bounded to 512 bytes. All ABI scalars are >= 32 bits.
typedef int32_t (*dm_online_packet_length_fn)(void *context, const uint8_t *header, uint32_t available);
void *dm_online_packets_open(dm_online_packet_length_fn resolver, void *context);
// Append: 0 accepted; -1 backpressure (retry same bytes after draining);
// -2 ended; -3 terminal parser error; -4 invalid args; -5 oversize input.
int32_t dm_online_packets_append(void *handle, const void *bytes, uint32_t length);
int32_t dm_online_packets_end(void *handle);
// Read: >0 one whole packet, kind=1 stock gameplay, kind=2 D2RL control.
// -1 need bytes; -2 clean EOF; -3 terminal error; -4 invalid args;
// -5 output buffer too small (packet retained for retry). kind is 0 on failure.
int32_t dm_online_packets_read(void *handle, void *bytes, uint32_t capacity, int32_t *kind);
// Error: 0 none, 1 unsupported stock packet, 2 length, 3 truncated EOF,
// 4 malformed control. A parsed control packet does not grant admission.
int32_t dm_online_packets_error(void *handle);
void dm_online_packets_release(void *handle);
#ifdef __cplusplus
}
#endif
