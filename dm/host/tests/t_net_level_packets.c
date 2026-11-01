#include "dm_net_level_packets.h"
#include "dm_net_level_allocations.h"
#include "dm_net_level_native.h"
#include "dm_net_binding.h"
#include <assert.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

static uint64_t generation;
static int isolated, failures;
static const void *held;
static uint32_t held_count;
uint64_t dm_net_remote_decode_generation(void) { return generation; }
int dm_online_save_isolated(void) { return isolated; }
uint32_t dm_net_remote_held_size(uint64_t g,int channel,const void *p) {
    return g==generation && channel==DM_NET_GAMEPLAY && p==held ? held_count : 0;
}
int dm_net_remote_fail(uint64_t g,int error) { assert(g==generation && error<0);failures++;return 0; }

static void *aligned(size_t n) { void *p=NULL;assert(!posix_memalign(&p,16,n));memset(p,0xa5,n);return p; }

int main(void) {
    unsigned char data[81];dm_net_level_packet p;
    const unsigned char ids[]={0x07,0x08,0x51,0x60,0x82};
    const unsigned sizes[]={7,7,15,14,81};
    for (unsigned i=0;i<5;i++) {
        memset(data,0,sizeof(data));data[0]=ids[i];
        for (unsigned n=0;n<sizes[i];n++) { p.opcode=42;assert(!dm_net_decode_level_packet(data,n,&p) && p.opcode==42); }
        assert(dm_net_decode_level_packet(data,sizes[i],&p));
        assert(!dm_net_decode_level_packet(data,sizes[i]+1,&p));
    }
    memset(data,0,sizeof(data));data[0]=0x82;memset(data+5,'x',61);
    assert(!dm_net_decode_level_packet(data,sizeof(data),&p));
    data[65]=0;assert(dm_net_decode_level_packet(data,sizeof(data),&p));

    for (unsigned op=7;op<=8;op++) for (unsigned value=0;value<=65535;value++) {
        unsigned char packet[7]={(unsigned char)op,0xff,0xff,0,0,(unsigned char)value,(unsigned char)(value>>8)};
        assert(dm_net_decode_level_packet(packet,7,&p) && p.level==value && p.x==65535 && p.y==0);
    }

    /* Registry churn retains one live object to force tombstone compaction. */
    const void *sentinel=(const void *)(uintptr_t)0x1000;
    assert(dm_net_level_allocation_add(sentinel));
    for (uintptr_t i=0;i<200000;i++) {
        const void *a=(const void *)(0x10000+i*16);
        assert(dm_net_level_allocation_add(a));assert(dm_net_level_allocation_has(a));
        dm_net_level_allocation_remove(a);assert(!dm_net_level_allocation_has(a));assert(dm_net_level_allocation_has(sentinel));
    }
    dm_net_level_allocation_remove(sentinel);
    for (uintptr_t i=0;i<65536;i++) assert(dm_net_level_allocation_add((const void *)(0x10000+i*16)));
    assert(!dm_net_level_allocation_add((const void *)(uintptr_t)0x400000));
    for (uintptr_t i=0;i<65536;i++) dm_net_level_allocation_remove((const void *)(0x10000+i*16));

    uint64_t regs[31],original[31];for (unsigned i=0;i<31;i++) regs[i]=original[i]=UINT64_C(0xabcdef000000)+i;
    generation=0;isolated=1;svc_net_level_entry(regs,(void *)0x1000,0x07);
    for (unsigned i=0;i<31;i++) assert(regs[i]==(i==8 ? 0 : original[i]));
    unsigned char room[7]={7,1,0,2,0,0x34,0x12};held=room;held_count=7;generation=7;
    regs[0]=(uintptr_t)room;svc_net_level_entry(regs,(void *)0x1000,7);assert(!regs[8]);
    regs[22]=(uintptr_t)room;assert(svc_net_level_field(regs,(void *)0x1000,0x2e6978));assert(regs[2]==0x1234);
    held_count=6;svc_net_level_entry(regs,(void *)0x1000,7);assert(regs[8]==1 && failures==1);
    held_count=7;isolated=0;regs[22]=(uintptr_t)room;assert(svc_net_level_field(regs,(void *)0x1000,0x2e6978));assert(regs[2]==0x34);

    /* Ordinary120-byte allocations must never touch the added high byte. */
    void *small=aligned(120);regs[19]=0x12340;
    assert(svc_net_level_field(regs,(void *)0x1000,0x4a5b38) && regs[1]==120);
    regs[0]=(uintptr_t)small;assert(svc_net_level_field(regs,(void *)0x1000,0x4a5b50));
    assert(!dm_net_level_allocation_has(small));free(small);
    isolated=1;void *wide=aligned(128);
    assert(svc_net_level_field(regs,(void *)0x1000,0x4a5b38) && regs[1]==128);
    regs[0]=(uintptr_t)wide;assert(svc_net_level_field(regs,(void *)0x1000,0x4a5b50));assert(dm_net_level_allocation_has(wide));
    for (unsigned i=112;i<128;i++) assert(!((unsigned char *)wide)[i]);
    regs[9]=(uintptr_t)wide;regs[8]=0xabcd;assert(svc_net_level_field(regs,(void *)0x1000,0x460470));
    assert(dm_net_object_interaction16(wide)==0xabcd && ((unsigned char *)wide)[9]==0xa5);
    regs[8]=(uintptr_t)wide;assert(svc_net_level_field(regs,(void *)0x1000,0x4a6800));assert(regs[9]==0xabcd);
    void *unit=aligned(448);*(uint32_t *)unit=2;memcpy((unsigned char *)unit+16,&wide,sizeof(wide));
    uint16_t level=0xf00f;memcpy((unsigned char *)unit+0x1be,&level,2);
    regs[0]=(uintptr_t)unit;assert(svc_net_level_field(regs,(void *)0x1000,0x2c0dc0));assert(regs[2]==0xf00f);
    generation=0;regs[1]=(uintptr_t)wide;
    assert(svc_net_level_field(regs,(void *)0x1000,0x1b6336c));assert(regs[8]==0x3212000 && !dm_net_level_allocation_has(wide));
    regs[8]=(uintptr_t)wide;assert(svc_net_level_field(regs,(void *)0x1000,0x4a6800));assert(regs[9]==0xcd);
    free(wide);free(unit);
    puts("Wide level packets: exact boundaries, full16-bit fields, allocation lifetime/churn, scoped receivers and original-layout fallback passed.");
}
