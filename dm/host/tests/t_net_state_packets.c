#include "dm_net_state_packets.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static unsigned calls, revivals, state_reads;
static uint64_t player_unit=42;
static uint64_t player(void *context) { (void)context;return player_unit; }
static void stat(void *context,uint64_t unit,uint32_t id,uint32_t value) {
    (void)context;(void)value;assert(unit==42);
    const uint32_t expected[]={6,8,10,74,26};assert(calls<5 && id==expected[calls++]);
}
static void position(void *context,uint64_t unit,uint32_t x,uint32_t y,uint32_t dx,uint32_t dy) {
    (void)context;assert(unit==42 && calls++==5 && x==1 && y==2 && dx==3 && dy==4);
}
static uint32_t unit_state(void *context,uint64_t unit) { (void)context;assert(unit==42);state_reads++;return 17; }
static void revive(void *context,uint64_t unit) { (void)context;assert(unit==42 && calls==6);revivals++; }
static int mana(void *context,uint64_t unit,uint32_t frame) { (void)context;assert(unit==42 && calls++==6 && frame==39);return 1; }

int main(void) {
    unsigned char input[] = {0x96,0x78,0x56,0x34,0x12,0xff,0xff,0,0,0x80,0x81};
    const unsigned char original[] = {0x96,0x78,0x56,0x34,0x12,0xff,0xff,0,0,0x80,0x81};
    dm_net_small_state decoded;
    assert(dm_net_decode_small_state(input, sizeof(input), &decoded));
    assert(decoded.resource == 0x12345678 && decoded.x == 65535 && decoded.y == 0);
    assert(decoded.destination_x == 127 && decoded.destination_y == 65409);
    assert(!memcmp(input, original, sizeof(input)));
    for (unsigned n = 0; n < sizeof(input); n++) {
        dm_net_small_state untouched = {.resource=42};
        assert(!dm_net_decode_small_state(input, n, &untouched) && untouched.resource == 42);
    }
    assert(!dm_net_decode_small_state(input, sizeof(input)+1, &decoded));
    input[0] = 0x95;
    assert(!dm_net_decode_small_state(input, sizeof(input), &decoded));

    const unsigned char medium[] = {0x95,0x78,0x56,0x34,0x12,0xef,0xcd,0xab,0x90,
        0xff,0xff,0xff,0xff,0xff,0xff,0,0,0x80,0x81,0xfe,0xff,0xff,0xff};
    dm_net_common_state common;
    assert(dm_net_decode_common_state(medium,sizeof(medium),&common));
    assert(common.life == 0x12345678 && common.mana == 0x90abcdef && common.stamina == UINT32_MAX);
    assert(common.frame == 0xfffffffe && common.destination_x == 127 && common.destination_y == 65409);
    for (unsigned n=0;n<sizeof(medium);n++) assert(!dm_net_decode_common_state(medium,n,&common));
    assert(!dm_net_decode_common_state(medium,sizeof(medium)+1,&common));

    dm_net_mana_ring ring={0}; int32_t result=0;
    ring.entries[0]=(dm_net_mana_entry){.delta=50,.frame=100,.active=2};
    ring.entries[1]=(dm_net_mana_entry){.delta=-200,.frame=100,.active=1};
    ring.entries[2]=(dm_net_mana_entry){.delta=-100,.frame=101,.active=1};
    ring.entries[3]=(dm_net_mana_entry){.delta=100,.frame=99,.active=1};
    assert(dm_net_predict_mana(&ring,100,100,&result));
    assert(result==50 && ring.reference_frame==100);
    assert(ring.entries[0].active==1 && !ring.entries[1].active && ring.entries[2].active==1 && !ring.entries[3].active);
    ring.next=16;dm_net_mana_ring before=ring;
    assert(!dm_net_predict_mana(&ring,101,100,&result) && !memcmp(&ring,&before,sizeof(ring)));
    memset(&ring,0,sizeof(ring));ring.next=15;
    ring.entries[15]=(dm_net_mana_entry){.delta=INT32_MAX,.frame=UINT32_MAX,.active=1};
    assert(dm_net_predict_mana(&ring,UINT32_MAX,1,&result) && result==INT32_MIN);
    dm_net_state_engine engine={.player=player,.set_stat=stat,.position=position,.unit_state=unit_state,.revive=revive,.mana_prediction=mana};
    common=(dm_net_common_state){.opcode=0x18,.life=1,.frame=UINT32_MAX,.x=1,.y=2,.destination_x=3,.destination_y=4};
    assert(dm_net_apply_common_state(&common,&engine) && calls==7 && revivals==1 && state_reads==1);
    calls=revivals=state_reads=0;common.life=0;
    assert(dm_net_apply_common_state(&common,&engine) && calls==7 && !revivals && !state_reads);
    calls=0;player_unit=0;
    assert(dm_net_apply_common_state(&common,&engine) && !calls);
    common.opcode=0xff;assert(!dm_net_apply_common_state(&common,&engine));
    puts("Extended states: boundaries, full resources, revival order, prediction expiry and wraparound passed.");
}
