#include "dm_net_state_packets.h"
#include <stddef.h>

static uint16_t little16(const unsigned char *p) {
    return (uint16_t)((uint32_t)p[0] | ((uint32_t)p[1] << 8));
}

int dm_net_decode_small_state(const void *packet, uint32_t count, dm_net_small_state *out) {
    if (!packet || !out || count != 11) return 0;
    const unsigned char *p = packet;
    if (p[0] != 0x96) return 0;
    dm_net_small_state decoded = {
        .resource = (uint32_t)p[1] | ((uint32_t)p[2] << 8) |
                    ((uint32_t)p[3] << 16) | ((uint32_t)p[4] << 24),
        .x = little16(p + 5), .y = little16(p + 7)
    };
    /* The original peer treats 0x80 as +128; only 0x81..0xff are negative. */
    int dx = p[9] <= 0x80 ? p[9] : (int)p[9] - 256;
    int dy = p[10] <= 0x80 ? p[10] : (int)p[10] - 256;
    decoded.destination_x = (uint16_t)(decoded.x + dx);
    decoded.destination_y = (uint16_t)(decoded.y + dy);
    *out = decoded;
    return 1;
}
