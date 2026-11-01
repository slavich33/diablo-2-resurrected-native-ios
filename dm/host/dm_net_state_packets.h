#pragma once
#include <stdint.h>

typedef struct {
    uint32_t resource;
    uint16_t x, y, destination_x, destination_y;
} dm_net_small_state;

/* Extended 0x96: 32-bit resource, two 16-bit coordinates and two signed
 * byte deltas. A separate explicit peer profile selects its 11-byte length. */
int dm_net_decode_small_state(const void *packet, uint32_t count, dm_net_small_state *out);

typedef struct {
    uint32_t life, mana, stamina, stat74, stat26, frame;
    uint16_t x, y, destination_x, destination_y;
    uint32_t opcode;
} dm_net_common_state;

int dm_net_decode_common_state(const void *packet, uint32_t count, dm_net_common_state *out);
uint32_t dm_net_state_packet_length(uint32_t opcode);

typedef struct {
    int32_t delta;
    uint32_t frame;
    uint8_t active, reserved[3];
} dm_net_mana_entry;
typedef struct {
    dm_net_mana_entry entries[16];
    int32_t next;
    uint32_t reference_frame;
} dm_net_mana_ring;

/* Match the native 32-bit prediction arithmetic, including unsigned frame
 * expiry and the signed insufficient-mana test. Invalid ring indices fail. */
int dm_net_predict_mana(dm_net_mana_ring *ring, uint32_t frame, int32_t baseline, int32_t *result);

typedef struct {
    void *context;
    uint64_t (*player)(void *);
    void (*set_stat)(void *, uint64_t, uint32_t, uint32_t);
    void (*position)(void *, uint64_t, uint32_t, uint32_t, uint32_t, uint32_t);
    uint32_t (*unit_state)(void *, uint64_t);
    void (*revive)(void *, uint64_t);
    int (*mana_prediction)(void *, uint64_t, uint32_t);
} dm_net_state_engine;

/* Apply decoded state in the original receiver's order. This API does not
 * select a role, authorize a session or make a server-save namespace. */
int dm_net_apply_common_state(const dm_net_common_state *state, const dm_net_state_engine *engine);
