/* Scoped exact-build replacement for the extended peer's small state reader.
 * Retail/unbound calls resume the original receiver. Wire bytes stay intact. */
#include "dm_net_state_packets.h"
#include "dm_net_binding.h"
#include "dm_save_completion.h"
#include <stddef.h>
#include <string.h>

void svc_net_small_state(uint64_t *regs, unsigned char *base) {
    regs[8] = 0;
    uint64_t generation = dm_net_remote_decode_generation();
    if (!generation || dm_online_save_isolated() != 1) return;
    regs[8] = 1;
    const void *packet = (const void *)(uintptr_t)regs[0];
    dm_net_small_state state;
    uint32_t count = dm_net_remote_held_size(generation, DM_NET_GAMEPLAY, packet);
    if (!base || !dm_net_decode_small_state(packet, count, &state)) {
        dm_net_remote_fail(generation, DM_NET_INVALID); return;
    }
    uint32_t player_id;
    memcpy(&player_id, base + 0x2d20e4c, sizeof(player_id));
    uint64_t unit = ((uint64_t (*)(uint32_t))(base + 0x45f9d0))(player_id);
    if (!unit) return;
    ((void (*)(uint64_t, uint32_t, uint32_t, uint32_t))(base + 0x5bc1f0))(
        unit, 0xa, state.resource << 8, 0);
    ((void (*)(uint64_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t))(base + 0x4b63c0))(
        unit, state.x, state.y, 0, state.destination_x, state.destination_y);
}
