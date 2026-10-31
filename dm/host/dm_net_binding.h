#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

enum { DM_NET_EMPTY = -1, DM_NET_CLOSED = -2, DM_NET_INVALID = -3,
       DM_NET_FULL = -4, DM_NET_SHORT = -5, DM_NET_STALE = -6 };
enum { DM_NET_SYSTEM = 0, DM_NET_GAMEPLAY = 1 };

// Complete game packets AFTER transport processing, not arbitrary TCP reads.
// Attach/detach only with the engine quiescent. This does not prepare its role,
// connect TCP, select a save mount, or authorize/admit a player.
uint64_t dm_net_remote_attach(uint64_t client);
int dm_net_remote_feed(uint64_t generation, int channel, const void *bytes, uint32_t count);
int dm_net_remote_read(uint64_t generation, void *bytes, uint32_t capacity);
int dm_net_remote_error(uint64_t generation);
int dm_net_remote_close(uint64_t generation);
int dm_net_remote_detach(uint64_t generation);

// Engine-only queue adapters. Return 1 for a bound client even after failure:
// a failed remote session must never fall back to the local game queues.
int dm_net_remote_send(uint64_t client, const uint64_t *span);
int dm_net_remote_poll(uint64_t client, int channel, uint64_t *cursor, void *optional_span);
#ifdef __cplusplus
}
#endif
