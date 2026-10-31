#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

enum { DM_NET_EMPTY = -1, DM_NET_CLOSED = -2, DM_NET_INVALID = -3,
       DM_NET_FULL = -4, DM_NET_SHORT = -5, DM_NET_STALE = -6, DM_NET_BUSY = -7 };
enum { DM_NET_SYSTEM = 0, DM_NET_GAMEPLAY = 1 };
enum { DM_NET_STARTUP_BYTES = 0x9d3 };

// Complete game packets AFTER transport processing, not arbitrary TCP reads.
// Attach/detach only with the engine quiescent. This does not prepare its role,
// connect TCP, select a save mount, or authorize/admit a player.
uint64_t dm_net_remote_attach(uint64_t client);
// Prepare a single startup transition with a 1..23-byte ASCII host and port.
// The coordinator must first select an isolated, verified server-save scope
// and validate admission/environment/transport. This API performs none of them.
// Call only while the engine is quiescent, before invoking its frontend flow.
int dm_net_remote_prepare_start(uint64_t generation, const char *host, uint32_t port);
int dm_net_remote_feed(uint64_t generation, int channel, const void *bytes, uint32_t count);
int dm_net_remote_read(uint64_t generation, void *bytes, uint32_t capacity);
int dm_net_remote_error(uint64_t generation);
// Mark the prepared packet pump usable only after verified remote setup.
// A TCP socket becoming writable is insufficient. This is not game admission.
// Connected requires this readiness and either original start/connect request.
int dm_net_remote_activate(uint64_t generation);
int dm_net_remote_connect_requested(uint64_t generation);
int dm_net_remote_start_requested(uint64_t generation);
int dm_net_remote_fail(uint64_t generation, int reason);
int dm_net_remote_close(uint64_t generation);
int dm_net_remote_detach(uint64_t generation);

// Engine-only queue adapters. Return 1 for a bound client even after failure:
// a failed remote session must never fall back to the local game queues.
int dm_net_remote_send(uint64_t client, const uint64_t *span);
int dm_net_remote_poll(uint64_t client, int channel, uint64_t *cursor, void *optional_span);
// Bound lifecycle/status adapters also suppress the original Nintendo backend.
// Outputs are only written for a bound client; all use the same queue lock.
int dm_net_remote_connect(uint64_t client);
int dm_net_remote_start(uint64_t client);
int dm_net_remote_can_connect(uint64_t client, int *result);
int dm_net_remote_status(uint64_t client, int *connected, int *failed);
int dm_net_remote_disconnect(uint64_t client);
// Exact-build startup gate only. 0 = unbound (unchanged), 1 = applied; negative
// = bound failure, so the gate must return false WITHOUT running local startup.
int dm_net_remote_apply_start(uint64_t client, void *startup, uint32_t capacity);
#ifdef __cplusplus
}
#endif
