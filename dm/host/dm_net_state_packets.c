#include "dm_net_state_packets.h"
#include <stddef.h>

_Static_assert(sizeof(dm_net_mana_entry) == 12, "native prediction entry");
_Static_assert(offsetof(dm_net_mana_ring, next) == 0xc0, "native prediction cursor");
_Static_assert(offsetof(dm_net_mana_ring, reference_frame) == 0xc4, "native prediction frame");

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

/* All callers below validate the exact fixed packet size before reading.
 * Big state has two 7-bit fields, so the remaining fields are not byte aligned. */
static uint32_t take_bits(const unsigned char *p, unsigned *offset, unsigned width) {
    uint32_t value = 0;
    for (unsigned i = 0; i < width; i++, (*offset)++)
        value |= (uint32_t)((p[*offset / 8] >> (*offset % 8)) & 1u) << i;
    return value;
}

uint32_t dm_net_state_packet_length(uint32_t opcode) {
    return opcode == 0x96 ? 11 : opcode == 0x95 ? 23 : opcode == 0x18 ? 25 : 0;
}
int dm_net_decode_common_state(const void *packet, uint32_t count, dm_net_common_state *out) {
    if (!packet || !out || !count) return 0;
    const unsigned char *p = packet;
    if (count != dm_net_state_packet_length(p[0])) return 0;
    dm_net_common_state state = {.opcode=p[0]};
    unsigned offset = 8;
    if (p[0] != 0x96) {
        state.life = take_bits(p, &offset, 32);
        state.mana = take_bits(p, &offset, 32);
    }
    state.stamina = take_bits(p, &offset, 32);
    if (p[0] == 0x18) {
        state.stat74 = take_bits(p, &offset, 7);
        state.stat26 = take_bits(p, &offset, 7);
    }
    state.x = (uint16_t)take_bits(p, &offset, 16);
    state.y = (uint16_t)take_bits(p, &offset, 16);
    uint32_t dx = take_bits(p, &offset, 8), dy = take_bits(p, &offset, 8);
    state.destination_x = (uint16_t)(state.x + (dx <= 0x80 ? (int)dx : (int)dx - 256));
    state.destination_y = (uint16_t)(state.y + (dy <= 0x80 ? (int)dy : (int)dy - 256));
    if (p[0] != 0x96) state.frame = take_bits(p, &offset, 32);
    *out = state;
    return 1;
}

int dm_net_predict_mana(dm_net_mana_ring *ring, uint32_t frame, int32_t baseline, int32_t *result) {
    if (!ring || !result || ring->next < 0 || ring->next >= 16) return 0;
    ring->reference_frame = frame;
    int32_t mana = baseline;
    for (unsigned i = 0; i < 16; i++) {
        dm_net_mana_entry *entry = &ring->entries[((unsigned)ring->next + i) % 16];
        int32_t magnitude = (int32_t)(0u - (uint32_t)entry->delta);
        if (!entry->active || entry->frame < frame || (entry->delta <= 0 && magnitude > mana)) {
            entry->active = 0;
        } else {
            mana = (int32_t)((uint32_t)mana + (uint32_t)entry->delta);
            entry->active = 1;
        }
    }
    *result = mana;
    return 1;
}

int dm_net_apply_common_state(const dm_net_common_state *s, const dm_net_state_engine *e) {
    if (!s || !e || !e->player || !e->set_stat || !e->position ||
        (s->opcode != 0x96 && s->opcode != 0x95 && s->opcode != 0x18)) return 0;
    if (s->opcode != 0x96 && (!e->unit_state || !e->revive || !e->mana_prediction)) return 0;
    uint64_t unit = e->player(e->context);
    if (!unit) return 1;
    if (s->opcode != 0x96) {
        e->set_stat(e->context, unit, 6, s->life << 8);
        e->set_stat(e->context, unit, 8, s->mana << 8);
    }
    e->set_stat(e->context, unit, 10, s->stamina << 8);
    if (s->opcode == 0x18) {
        e->set_stat(e->context, unit, 74, s->stat74);
        e->set_stat(e->context, unit, 26, s->stat26);
    }
    e->position(e->context, unit, s->x, s->y, s->destination_x, s->destination_y);
    if (s->opcode == 0x96) return 1;
    if (s->life && e->unit_state(e->context, unit) == 17) e->revive(e->context, unit);
    return e->mana_prediction(e->context, unit, s->frame + 40u);
}
