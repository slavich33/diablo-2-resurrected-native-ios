#pragma once
#include <stdint.h>

typedef struct {
    uint32_t resource;
    uint16_t x, y, destination_x, destination_y;
} dm_net_small_state;

/* Extended 0x96: 32-bit resource, two 16-bit coordinates and two signed
 * byte deltas. A separate explicit peer profile selects its 11-byte length. */
int dm_net_decode_small_state(const void *packet, uint32_t count, dm_net_small_state *out);
