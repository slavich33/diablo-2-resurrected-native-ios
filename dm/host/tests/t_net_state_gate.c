#include "dm_net_state_packets.h"
#include "dm_net_binding.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

extern void svc_net_common_state(uint64_t *, unsigned char *, uint32_t);
extern void svc_net_state_length(uint64_t *);
static uint64_t generation;
static int isolated, failure;
static uint32_t size;
static const void *held;
uint64_t dm_net_remote_decode_generation(void) { return generation; }
int dm_online_save_isolated(void) { return isolated; }
uint32_t dm_net_remote_held_size(uint64_t g, int channel, const void *p) {
    assert(g == generation && channel == DM_NET_GAMEPLAY);
    return p == held ? size : 0;
}
int dm_net_remote_fail(uint64_t g, int reason) { assert(g == generation); failure=reason; return 0; }

int main(void) {
    uint64_t regs[31], before[31];
    unsigned char packet[25]={0x95};
    for (unsigned i=0;i<31;i++) regs[i]=i+10;
    regs[0]=(uintptr_t)packet;memcpy(before,regs,sizeof(regs));
    svc_net_common_state(regs,(void *)1,0x95);
    before[8]=0;assert(!memcmp(regs,before,sizeof(regs)) && !failure);
    generation=7;svc_net_common_state(regs,(void *)1,0x95);
    assert(!memcmp(regs,before,sizeof(regs)) && !failure);
    isolated=1;svc_net_common_state(regs,(void *)1,0x95);
    before[8]=1;assert(!memcmp(regs,before,sizeof(regs)) && failure==DM_NET_INVALID);
    failure=0;held=packet;size=23;
    svc_net_common_state(regs,(void *)1,0x18); // Wrong receiver, before guest access.
    assert(failure==DM_NET_INVALID);
    failure=0;svc_net_common_state(regs,NULL,0x95);assert(failure==DM_NET_INVALID);
    for (unsigned mode=0;mode<3;mode++) {
        generation=mode>0?7:0;isolated=mode==2;
        for (unsigned opcode=0;opcode<256;opcode++) {
            regs[8]=99;regs[27]=opcode;memcpy(before,regs,sizeof(regs));
            svc_net_state_length(regs);
            uint32_t length=dm_net_state_packet_length(opcode);
            if (mode==2 && length) before[8]=length;
            assert(!memcmp(regs,before,sizeof(regs)));
        }
    }
    puts("State gate: isolated activation, exact span/receiver and scoped dispatcher lengths required.");
}
