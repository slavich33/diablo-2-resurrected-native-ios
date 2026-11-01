/* Scoped exact-build replacements for the extended peer's state readers.
 * Retail/unbound calls resume the original receiver. Wire bytes stay intact. */
#include "dm_net_state_packets.h"
#include "dm_net_binding.h"
#include "dm_save_completion.h"
#include <stddef.h>
#include <string.h>

void svc_net_state_length(uint64_t *regs) {
    if (!dm_net_remote_decode_generation() || dm_online_save_isolated() != 1) return;
    uint32_t length = dm_net_state_packet_length((uint32_t)regs[27]);
    if (length) regs[8] = length;
}

static uint64_t native_player(void *context) {
    unsigned char *base = context;
    uint32_t player_id;
    memcpy(&player_id, base + 0x2d20e4c, sizeof(player_id));
    return ((uint64_t (*)(uint32_t))(base + 0x45f9d0))(player_id);
}
static void native_stat(void *context, uint64_t unit, uint32_t id, uint32_t value) {
    unsigned char *base = context;
    ((void (*)(uint64_t, uint32_t, uint32_t, uint32_t))(base + 0x5bc1f0))(unit, id, value, 0);
}
static void native_position(void *context, uint64_t unit, uint32_t x, uint32_t y, uint32_t dx, uint32_t dy) {
    unsigned char *base = context;
    ((void (*)(uint64_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t))(base + 0x4b63c0))(unit, x, y, 0, dx, dy);
}
static uint32_t native_unit_state(void *context, uint64_t unit) {
    (void)context;
    uint32_t state;
    memcpy(&state, (const unsigned char *)(uintptr_t)unit + 0xc, sizeof(state));
    return state;
}
static void native_revive(void *context, uint64_t unit) {
    unsigned char *base = context, *flags_at = (unsigned char *)(uintptr_t)unit + 0x124;
    uint32_t flags;
    memcpy(&flags, flags_at, sizeof(flags)); flags &= ~0x40u;
    memcpy(flags_at, &flags, sizeof(flags));
    if (((uint32_t (*)(uint64_t, uint32_t))(base + 0x460fd0))(unit, 5)) {
        ((void (*)(uint64_t, uint32_t))(base + 0x298d70))(unit, 0);
        ((void (*)(uint64_t, uint32_t, uint32_t))(base + 0x4bbc50))(unit, 5, 0);
    }
    ((void (*)(uint64_t))(base + 0x4666a0))(unit);
}
static int native_mana_prediction(void *context, uint64_t unit, uint32_t frame) {
    unsigned char *base = context;
    uintptr_t player_data, ring_pointer;
    memcpy(&player_data, (const unsigned char *)(uintptr_t)unit + 0x10, sizeof(player_data));
    if (!player_data) return 0;
    memcpy(&ring_pointer, (const unsigned char *)player_data + 0x218, sizeof(ring_pointer));
    dm_net_mana_ring *ring = (dm_net_mana_ring *)ring_pointer;
    if (!ring || ring->next < 0 || ring->next >= 16) return 0;
    ring->reference_frame = frame;
    int32_t baseline = (int32_t)((uint32_t (*)(uint64_t, uint32_t, uint32_t))(base + 0x5b9290))(unit, 8, 0);
    int32_t updated;
    if (!dm_net_predict_mana(ring, frame, baseline, &updated)) return 0;
    if (updated != baseline) native_stat(context, unit, 8, (uint32_t)updated);
    return 1;
}

void svc_net_common_state(uint64_t *regs, unsigned char *base, uint32_t opcode) {
    regs[8] = 0;
    uint64_t generation = dm_net_remote_decode_generation();
    if (!generation || dm_online_save_isolated() != 1) return;
    regs[8] = 1;
    const void *packet = (const void *)(uintptr_t)regs[0];
    dm_net_common_state state;
    uint32_t count = dm_net_remote_held_size(generation, DM_NET_GAMEPLAY, packet);
    if (!base || !dm_net_decode_common_state(packet, count, &state) || state.opcode != opcode) {
        dm_net_remote_fail(generation, DM_NET_INVALID); return;
    }
    dm_net_state_engine engine = {
        .context=base, .player=native_player, .set_stat=native_stat, .position=native_position,
        .unit_state=native_unit_state, .revive=native_revive, .mana_prediction=native_mana_prediction
    };
    if (!dm_net_apply_common_state(&state, &engine)) dm_net_remote_fail(generation, DM_NET_INVALID);
}
void svc_net_small_state(uint64_t *regs, unsigned char *base) {
    svc_net_common_state(regs, base, 0x96);
}
