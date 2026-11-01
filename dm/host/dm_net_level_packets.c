#include "dm_net_level_packets.h"
#include <string.h>

static uint16_t word(const unsigned char *p) {
    return (uint16_t)((uint16_t)p[0] | (uint16_t)p[1] << 8);
}
static uint32_t dword(const unsigned char *p) {
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

uint32_t dm_net_level_packet_length(uint32_t opcode) {
    switch (opcode) {
    case 0x07: case 0x08: return 7;
    case 0x51: return 15;
    case 0x60: return 14;
    case 0x82: return 81;
    default: return 0;
    }
}

int dm_net_decode_level_packet(const void *bytes, uint32_t count, dm_net_level_packet *out) {
    if (!bytes || !count || !out) return 0;
    const unsigned char *p = bytes;
    if (!dm_net_level_packet_length(p[0]) || count != dm_net_level_packet_length(p[0])) return 0;
    dm_net_level_packet value = {.opcode=p[0]};
    switch (value.opcode) {
    case 0x07: case 0x08:
        value.x=word(p+1); value.y=word(p+3); value.level=word(p+5);
        break;
    case 0x51:
        value.kind=p[1]; value.unit_id=dword(p+2); value.class_id=word(p+6);
        value.x=word(p+8); value.y=word(p+10); value.mode=p[12]; value.interaction=word(p+13);
        break;
    case 0x60:
        value.flags=p[1]; value.interaction=word(p+2); value.unit_id=dword(p+4);
        value.x=word(p+8); value.y=word(p+10); value.level=word(p+12);
        break;
    case 0x82:
        if (!memchr(p+5, 0, sizeof(value.owner))) return 0;
        value.owner_id=dword(p+1); memcpy(value.owner, p+5, sizeof(value.owner));
        value.unit_id=dword(p+66); value.partner_id=dword(p+70);
        value.level=word(p+74); value.x=word(p+76); value.y=word(p+78); value.flags=p[80];
        break;
    }
    *out=value;
    return 1;
}

uint16_t dm_net_object_interaction16(const void *object_data) {
    const unsigned char *p=object_data;
    return (uint16_t)((uint16_t)p[8] | (uint16_t)p[0x78] << 8);
}
void dm_net_set_object_interaction16(void *object_data, uint16_t value) {
    unsigned char *p=object_data;
    p[8]=(unsigned char)value; p[0x78]=(unsigned char)(value >> 8);
}

int dm_net_apply_warp_destination(const dm_net_level_packet *p, const dm_net_level_engine *e) {
    if (!p || p->opcode!=0x60 || !e || !e->object || !e->interaction || !e->flags_or ||
        !e->position || !e->destination) return 0;
    uint64_t unit=e->object(e->context,p->unit_id);
    if (!unit) return 1;
    e->interaction(e->context,unit,p->interaction);
    e->flags_or(e->context,unit,(uint8_t)(p->flags & 3));
    e->destination(e->context,unit,p->level);
    if (p->level) e->position(e->context,unit,p->x,p->y);
    return 1;
}

int dm_net_apply_portal_link(const dm_net_level_packet *p, const dm_net_level_engine *e) {
    if (!p || p->opcode!=0x82 || !e || !e->object || !e->owner || !e->position ||
        !e->destination || !e->link_state || !e->link || !memchr(p->owner,0,sizeof(p->owner))) return 0;
    uint64_t unit=e->object(e->context,p->unit_id);
    if (unit) {
        e->owner(e->context,unit,p->owner);
        e->position(e->context,unit,p->x,p->y);
        e->destination(e->context,unit,p->level);
        e->link_state(e->context,unit,p->flags);
    }
    if (p->partner_id!=UINT32_MAX) {
        unit=e->object(e->context,p->partner_id);
        if (unit) {
            e->owner(e->context,unit,p->owner);
            e->link_state(e->context,unit,p->flags);
        }
        e->link(e->context,p->owner_id,p->unit_id,p->partner_id);
    }
    return 1;
}
