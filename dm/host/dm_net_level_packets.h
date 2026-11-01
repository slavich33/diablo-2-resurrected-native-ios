#pragma once
#include <stdint.h>

/* Explicit extended-peer layouts, not the stock engine's packet table. */
typedef struct {
    uint32_t opcode, unit_id, partner_id, owner_id;
    uint16_t x, y, level, interaction, class_id;
    uint8_t kind, flags, mode;
    unsigned char owner[61];
} dm_net_level_packet;

uint32_t dm_net_level_packet_length(uint32_t opcode);
int dm_net_decode_level_packet(const void *bytes, uint32_t count, dm_net_level_packet *out);

/* Object interaction uses the original low-byte field and a separate high
 * byte. Byte9 remains the object's flags. Call only on an actual object-data
 * allocation of at least0x79 bytes, never on an arbitrary unit-data variant. */
uint16_t dm_net_object_interaction16(const void *object_data);
void dm_net_set_object_interaction16(void *object_data, uint16_t value);

typedef struct {
    void *context;
    uint64_t (*object)(void *, uint32_t);
    void (*interaction)(void *, uint64_t, uint16_t);
    void (*flags_or)(void *, uint64_t, uint8_t);
    void (*position)(void *, uint64_t, uint16_t, uint16_t);
    void (*destination)(void *, uint64_t, uint16_t);
    void (*owner)(void *, uint64_t, const unsigned char *);
    void (*link_state)(void *, uint64_t, uint8_t);
    void (*link)(void *, uint32_t, uint32_t, uint32_t);
} dm_net_level_engine;

/* Preserve the original peer's update order and missing-object no-ops. These
 * pure dispatchers do not admit a session, mount a save or send any packet. */
int dm_net_apply_warp_destination(const dm_net_level_packet *, const dm_net_level_engine *);
int dm_net_apply_portal_link(const dm_net_level_packet *, const dm_net_level_engine *);
