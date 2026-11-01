/* Exact-build, opt-in peer adapters. Original wire bytes stay intact. */
#include "dm_net_level_native.h"
#include "dm_net_level_packets.h"
#include "dm_net_level_allocations.h"
#include "dm_net_binding.h"
#include "dm_save_completion.h"
#include <stddef.h>
#include <string.h>

enum { DM_LEVEL_ROOM_LEVEL, DM_LEVEL_CREATE_LEVEL, DM_LEVEL_OBJECT_GET,
       DM_LEVEL_OBJECT_SET, DM_LEVEL_DESTINATION, DM_LEVEL_ALLOCATE,
       DM_LEVEL_INITIALIZE, DM_LEVEL_RELEASE };
typedef struct { uint32_t site, word; uint8_t base, value, kind; } field_site;
static const field_site fields[]={
#define DM_LEVEL_FIELD(site,word,base,value,kind) {site,word,base,value,DM_LEVEL_##kind},
#include "dm_net_level_sites.inc"
#undef DM_LEVEL_FIELD
};
typedef struct {
    unsigned char *base;
    const void *wire;
    uint64_t generation;
    dm_net_level_packet packet;
    int failed;
} level_context;
static _Thread_local level_context current;
static _Thread_local uintptr_t allocating_unit;
static _Thread_local int allocating_wide;

static uint64_t peer_generation(void) {
    return dm_online_save_isolated()==1 ? dm_net_remote_decode_generation() : 0;
}
static uint32_t read32(const void *p) { uint32_t v;memcpy(&v,p,4);return v; }
static uint16_t read16(const void *p) { uint16_t v;memcpy(&v,p,2);return v; }
static void put16(void *p,uint16_t v) { memcpy(p,&v,2); }
static unsigned char *object_data(uint64_t unit) {
    if (!unit) return NULL;
    const unsigned char *u=(const unsigned char *)(uintptr_t)unit;
    if (read32(u)!=2) return NULL;
    uintptr_t data;memcpy(&data,u+0x10,sizeof(data));
    return dm_net_level_allocation_has((const void *)data) ? (unsigned char *)data : NULL;
}
static int current_packet(void) {
    return current.generation && peer_generation()==current.generation &&
        dm_net_remote_held_size(current.generation,DM_NET_GAMEPLAY,current.wire)==
            dm_net_level_packet_length(current.packet.opcode);
}
static uint64_t object(void *context,uint32_t id) {
    level_context *c=context;
    uint64_t u=((uint64_t (*)(void *,uint32_t,uint32_t,uint32_t))(c->base+0x45f5f0))(
        c->base+0x2d60ba0,id & 127,id,2);
    if (u && !object_data(u)) { c->failed=1;return 0; }
    return u;
}
static void interaction(void *context,uint64_t unit,uint16_t value) {
    unsigned char *data=object_data(unit);
    if (!data) { ((level_context *)context)->failed=1;return; }
    dm_net_set_object_interaction16(data,value);
}
static void flags_or(void *context,uint64_t unit,uint8_t value) {
    unsigned char *data=object_data(unit);
    if (!data) { ((level_context *)context)->failed=1;return; }
    data[9]|=value;
}
static void position(void *context,uint64_t unit,uint16_t x,uint16_t y) {
    (void)context;unsigned char *u=(unsigned char *)(uintptr_t)unit;
    put16(u+0x1b6,x);put16(u+0x1b8,y);
}
static void destination(void *context,uint64_t unit,uint16_t level) {
    (void)context;put16((unsigned char *)(uintptr_t)unit+0x1be,level);
}
static void owner(void *context,uint64_t unit,const unsigned char *name) {
    unsigned char *data=object_data(unit);
    if (!data) { ((level_context *)context)->failed=1;return; }
    size_t n=0;while (n<60 && name[n]) n++;
    memcpy(data+0x34,name,n);data[0x34+n]=0;
}
static void link_state(void *context,uint64_t unit,uint8_t flags) {
    (void)context;*((unsigned char *)(uintptr_t)unit+0x1bb)=flags;
}
static void link(void *context,uint32_t owner_id,uint32_t first,uint32_t second) {
    level_context *c=context;
    if (!c->failed) ((void (*)(uint32_t,uint32_t,uint32_t))(c->base+0x2e1660))(owner_id,first,second);
}

void svc_net_level_length(uint64_t *regs) {
    if (!peer_generation()) return;
    uint32_t count=dm_net_level_packet_length((uint32_t)regs[27]);
    if (count) regs[8]=count;
}

void svc_net_level_entry(uint64_t *regs,unsigned char *base,uint32_t opcode) {
    regs[8]=0;
    uint64_t generation=peer_generation();
    if (!generation) return;
    const void *wire=(const void *)(uintptr_t)regs[0];
    uint32_t count=dm_net_remote_held_size(generation,DM_NET_GAMEPLAY,wire);
    dm_net_level_packet packet;
    if (!base || !dm_net_decode_level_packet(wire,count,&packet) || packet.opcode!=opcode ||
        (opcode==0x51 && packet.kind>5)) {
        regs[8]=1;dm_net_remote_fail(generation,DM_NET_INVALID);return;
    }
    level_context previous=current;
    current=(level_context){.base=base,.wire=wire,.generation=generation,.packet=packet};
    if (opcode==0x07 || opcode==0x08) return; /* Original map body; only its level read changes. */
    if (opcode==0x51) {
        uint32_t act=*(base+0x2127c48);
        uint64_t unit=((uint64_t (*)(uint32_t,uint32_t,uint32_t,uint32_t,uint32_t,
                                     uint32_t,uint32_t,uint32_t,uint32_t))(base+0x4603f0))(
            act,packet.unit_id,packet.class_id,packet.x,packet.y,packet.kind,0,packet.mode,packet.interaction);
        regs[0]=unit;
        if (unit && packet.kind==2 && !object_data(unit)) current.failed=1;
    } else {
        dm_net_level_engine engine={.context=&current,.object=object,.interaction=interaction,
            .flags_or=flags_or,.position=position,.destination=destination,.owner=owner,
            .link_state=link_state,.link=link};
        int ok=opcode==0x60 ? dm_net_apply_warp_destination(&packet,&engine) :
               opcode==0x82 ? dm_net_apply_portal_link(&packet,&engine) : 0;
        if (!ok) current.failed=1;
    }
    if (current.failed) dm_net_remote_fail(generation,DM_NET_INVALID);
    current=previous;regs[8]=1;
}

int svc_net_level_field(uint64_t *regs,unsigned char *base,uint64_t site) {
    size_t lo=0,hi=sizeof(fields)/sizeof(fields[0]);
    while (lo<hi) { size_t mid=lo+(hi-lo)/2;if (fields[mid].site<site) lo=mid+1;else hi=mid; }
    if (lo==sizeof(fields)/sizeof(fields[0]) || fields[lo].site!=site) return 0;
    const field_site *f=&fields[lo];
    unsigned char *p=(unsigned char *)(uintptr_t)regs[f->base];
    switch (f->kind) {
    case DM_LEVEL_ROOM_LEVEL:
        regs[f->value]=current_packet() && current.wire==p &&
            (current.packet.opcode==0x07 || current.packet.opcode==0x08) ? current.packet.level : p[5];
        break;
    case DM_LEVEL_CREATE_LEVEL: {
        uint64_t unit=regs[20];
        int matched=current_packet() && current.packet.opcode==0x51 && unit &&
            read32((const void *)(uintptr_t)unit)==2 &&
            read32((const unsigned char *)(uintptr_t)unit+8)==current.packet.unit_id;
        regs[f->value]=matched ? current.packet.interaction : p[0x10];break;
    }
    case DM_LEVEL_OBJECT_GET:
        regs[f->value]=dm_net_level_allocation_has(p) ? dm_net_object_interaction16(p) : p[8];break;
    case DM_LEVEL_OBJECT_SET:
        if (dm_net_level_allocation_has(p)) dm_net_set_object_interaction16(p,(uint16_t)regs[f->value]);
        else p[8]=(unsigned char)regs[f->value];
        break;
    case DM_LEVEL_DESTINATION:
        regs[f->value]=object_data((uintptr_t)p) ? read16(p+0x1be) : p[0x1ba];break;
    case DM_LEVEL_ALLOCATE:
        allocating_wide=peer_generation()!=0;allocating_unit=regs[19];
        regs[1]=allocating_wide ? 0x80 : 0x78;break;
    case DM_LEVEL_INITIALIZE:
        memset(p+0x70,0,8);
        if (allocating_wide && allocating_unit==regs[19]) {
            memset(p+0x78,0,8);
            if (!dm_net_level_allocation_add(p)) {
                current.failed=1;uint64_t generation=peer_generation();
                if (generation) dm_net_remote_fail(generation,DM_NET_FULL);
            }
        }
        allocating_wide=0;break;
    case DM_LEVEL_RELEASE:
        dm_net_level_allocation_remove(p);regs[8]=(uintptr_t)base+0x3211000;break;
    }
    return 1;
}
