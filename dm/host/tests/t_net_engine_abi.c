#include "../dm_net_engine.h"
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern uint64_t dm_net_test_send(void);
extern uint64_t dm_net_test_receive(void);
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
    uint32_t error = 0xffffffff;
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
    puts("ARM64 engine shims passed: send target, hidden x8 result, error output and bounded metadata trace.");
    return 0;
}
