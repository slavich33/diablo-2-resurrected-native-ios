#include "../dm_net_engine.h"
#include "../dm_net_binding.h"
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern uint64_t dm_net_test_send(void);
extern uint64_t dm_net_test_receive(void);
extern void dm_net_test_receive_body(void);
extern void dm_net_test_send_body(void);
extern const unsigned char dm_net_test_packet[4];

int main(int argc, char **argv) {
    assert(argc == 2);
    setenv("DM_NET_ENGINE_TRACE", argv[1], 1);
    const unsigned char packet[] = {0x3c, 1, 2, 3};
    uint64_t span[] = {(uintptr_t)packet, (uintptr_t)(packet + sizeof(packet))};
    uint64_t regs[31] = {0};
    regs[0] = 0x1234; regs[1] = (uintptr_t)span; regs[8] = (uintptr_t)dm_net_test_send;
    svc_net_client_send(regs);
    assert(regs[0] == 0x5a5a);

    _Alignas(8) unsigned char result[24]; memset(result, 0xa5, sizeof(result));
    uint64_t error = UINT64_MAX;
    memset(regs, 0, sizeof(regs));
    regs[0] = 0x1234; regs[1] = (uintptr_t)&error;
    regs[8] = (uintptr_t)result; regs[9] = (uintptr_t)dm_net_test_receive;
    svc_net_client_poll(regs);
    assert(regs[0] == 0x6b6b && error == 0 && result[16] == 1);
    uint64_t *received = (uint64_t *)result;
    assert(received[0] == (uintptr_t)dm_net_test_packet && received[1] - received[0] == 4);
    assert(!memcmp((const void *)(uintptr_t)received[0], dm_net_test_packet, 4));
    for (int i = 17; i < 24; i++) assert(result[i] == 0xa5);
    FILE *trace = fopen(argv[1], "r"); assert(trace);
    char line[512]; assert(fgets(line, sizeof(line), trace));
    assert(strstr(line, "\"direction\":\"c2s\"") && strstr(line, "\"length\":4"));
    assert(fgets(line, sizeof(line), trace));
    assert(strstr(line, "\"direction\":\"s2c\"") && strstr(line, "\"length\":4"));
    assert(!fgets(line, sizeof(line), trace)); fclose(trace);
    memset(regs, 0, sizeof(regs));
    regs[0] = 0x1234; regs[1] = (uintptr_t)span;
    svc_net_queue_send(regs, (uintptr_t)dm_net_test_send_body);
    assert(regs[0] == 0x5a5a);
    for (int gameplay = 0; gameplay <= 1; gameplay++) {
        memset(result, 0xa5, sizeof(result)); error = UINT64_MAX;
        memset(regs, 0, sizeof(regs));
        regs[0] = 0x1234; regs[1] = (uintptr_t)&error; regs[8] = (uintptr_t)result;
        svc_net_queue_poll(regs, (uintptr_t)dm_net_test_receive_body, gameplay);
        assert(regs[0] == 0x6b6b && error == 0 && result[16] == 1);
        assert(received[0] == (uintptr_t)dm_net_test_packet && received[1] - received[0] == 4);
        for (int i = 17; i < 24; i++) assert(result[i] == 0xa5);
    }
    uint64_t generation = dm_net_remote_attach(0x1234);
    assert(generation && !dm_net_remote_attach(0x5678));
    assert(!dm_net_remote_send(0x5678, span));
    memset(regs, 0, sizeof(regs)); regs[0] = 0x1234; regs[1] = (uintptr_t)span;
    // A null continuation would fault if bound traffic fell through locally.
    svc_net_queue_send(regs, 0);
    unsigned char outbound[8];
    assert(dm_net_remote_read(generation, outbound, 1) == DM_NET_SHORT);
    assert(dm_net_remote_read(generation, outbound, sizeof(outbound)) == 4);
    assert(!memcmp(outbound, packet, 4));
    assert(dm_net_remote_read(generation, outbound, sizeof(outbound)) == DM_NET_EMPTY);
    unsigned char incoming[] = {0x01, 2, 3, 4};
    assert(!dm_net_remote_feed(generation, DM_NET_GAMEPLAY, incoming, sizeof(incoming)));
    incoming[0] = 0xff;  // the queue owns a copy, not the producer's buffer
    memset(result, 0xa5, sizeof(result)); error = UINT64_MAX;
    memset(regs, 0, sizeof(regs)); regs[0] = 0x1234;
    regs[1] = (uintptr_t)&error; regs[8] = (uintptr_t)result;
    svc_net_queue_poll(regs, 0, 1);
    assert(result[16] == 1 && error == 0 && received[1] - received[0] == 4);
    const unsigned char *borrowed = (const void *)(uintptr_t)received[0];
    assert(borrowed[0] == 0x01);
    for (int i = 17; i < 24; i++) assert(result[i] == 0xa5);
    assert(!dm_net_remote_close(generation));
    assert(borrowed[0] == 0x01); // asynchronous close retains a live borrowed span
    regs[0] = 0x1234;
    svc_net_queue_poll(regs, 0, 1);
    assert(!result[16]);
    assert(dm_net_remote_read(generation, outbound, sizeof(outbound)) == DM_NET_CLOSED);
    regs[0] = 0x1234; regs[1] = (uintptr_t)span;
    svc_net_queue_send(regs, 0); // failed remote session never falls back locally
    assert(!dm_net_remote_detach(generation));
    uint64_t next = dm_net_remote_attach(0x1234); assert(next && next != generation);
    assert(dm_net_remote_feed(generation, DM_NET_SYSTEM, packet, 4) == DM_NET_STALE);
    for (int i = 0; i < 1024; i++) assert(!dm_net_remote_feed(next, DM_NET_SYSTEM, packet, 1));
    assert(dm_net_remote_feed(next, DM_NET_SYSTEM, packet, 1) == DM_NET_FULL);
    assert(dm_net_remote_error(next) == DM_NET_FULL);
    assert(!dm_net_remote_detach(next));
    puts("ARM64 engine shims passed: prologue/hidden x8, remote queue routing, retained retry, span lifetime, stale generation and overflow disconnect.");
    return 0;
}
