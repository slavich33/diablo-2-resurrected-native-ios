#include "dm_item_format.h"
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
extern void svc_item_format_flags(uint64_t *);
static uint64_t generation;
static int isolated;
uint64_t dm_net_remote_decode_generation(void) { return generation; }
int dm_online_save_isolated(void) { return isolated; }

int main(void) {
    const unsigned char input[]={0x10,0,0x28,0,5,0xab};
    dm_item_bits original={.cursor=input+4,.bit_count=48,.consumed_bytes=4};
    uint64_t regs[31],before[31];
    for (unsigned i=0;i<31;i++) regs[i]=100+i;
    regs[0]=0x280010;regs[1]=(uintptr_t)&original;
    memcpy(before,regs,sizeof(regs));
    svc_item_format_flags(regs);
    assert(!memcmp(regs,before,sizeof(regs)) && original.consumed_bytes==4);
    generation=1;svc_item_format_flags(regs);
    assert(!memcmp(regs,before,sizeof(regs)) && original.consumed_bytes==4);
    isolated=1;svc_item_format_flags(regs);
    assert(regs[0]==0x200010 && original.consumed_bytes==5 && original.cursor==input+5 && !original.error);
    assert(!memcmp(regs+1,before+1,sizeof(regs)-8));
    original=(dm_item_bits){.cursor=input+4,.bit_count=48,.consumed_bytes=4};
    regs[0]=0x200010;svc_item_format_flags(regs);
    assert(regs[0]==0x200010 && original.consumed_bytes==4);
    unsigned char unknown[]={0x10,0,0x28,0,6};
    original=(dm_item_bits){.cursor=unknown+4,.bit_count=40,.consumed_bytes=4};
    regs[0]=0x280010;svc_item_format_flags(regs);
    assert(original.error && original.consumed_bytes==5);
    puts("Native item service: active isolated scope required, retail untouched, invalid schema fails.");
}
