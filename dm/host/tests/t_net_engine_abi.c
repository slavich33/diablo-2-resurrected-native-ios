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
extern void dm_net_test_connected_body(void);
extern void dm_net_test_failed_body(void);
extern void dm_net_test_hard_close_body(void);
extern void dm_net_test_graceful_close_body(void);
extern uint64_t dm_net_test_connect_gate(uint64_t, uint64_t, uint64_t, uint64_t,
                                         uint64_t, uint64_t, uint64_t, uint64_t, uint64_t);
extern uint64_t dm_net_test_start_gate(uint64_t, uint64_t, uint64_t, uint64_t,
                                       uint64_t, uint64_t, uint64_t, uint64_t, uint64_t);
extern uint64_t dm_net_test_bootstrap_gate(uint64_t, uint64_t, uint64_t, uint64_t,
                                           uint64_t, uint64_t, uint64_t, uint64_t, uint64_t);

// The connect fixture enters the real assembly gate. Other shims are called
// directly; a separate game run checks the actual module/metadata dispatcher.
static int start_gate;
uint64_t gate_dispatch(uint64_t pc, uint64_t *regs) {
    (void)pc;
    if (start_gate == 2) svc_net_bootstrap_guard(regs, 0x1234);
    else if (start_gate) svc_net_start_guard(regs); else svc_net_connect_guard(regs);
    return regs[0];
}
uint64_t unimpl_c(unsigned index, uint64_t *regs) { (void)index; (void)regs; abort(); }
void dm_thread_returned(void) { abort(); }

static void bootstrap_tests(void) {
    unsigned char input[DM_NET_STARTUP_BYTES + 16], before[sizeof(input)];
    memset(input, 0xa5, sizeof(input)); memset(input + 0x39, 0, 4);
    memcpy(before, input, sizeof(input));
    // No binding: the real assembly branch gate resumes the original prologue,
    // preserving x8, flags and all nine argument positions.
    start_gate = 2;
    uint64_t pointer = (uintptr_t)input;
    assert(dm_net_test_bootstrap_gate(pointer, 1, 2, 3, 4, 5, 6, 7, 8) == pointer + 36);
    assert(!memcmp(input, before, sizeof(input)));
    uint64_t g = dm_net_remote_attach(0x1234); assert(g);
    assert(dm_net_remote_prepare_start(g, "", 4000) == DM_NET_INVALID);
    assert(dm_net_remote_prepare_start(g, "127.0.0.1", 0) == DM_NET_INVALID);
    assert(dm_net_remote_prepare_start(g, "127.0.0.1", 65536) == DM_NET_INVALID);
    assert(dm_net_remote_prepare_start(g, "abcdefghijklmnopqrstuvwx", 4000) == DM_NET_INVALID);
    assert(dm_net_remote_prepare_start(g, "host/path", 4000) == DM_NET_INVALID);
    assert(!dm_net_remote_error(g));
    char host[] = "127.0.0.1";
    assert(!dm_net_remote_prepare_start(g, host, 49152)); host[0] = '9';
    assert(dm_net_remote_prepare_start(g, "other", 4000) == DM_NET_BUSY);
    assert(dm_net_remote_apply_start(0x5678, NULL, 0) == 0);
    assert(dm_net_test_bootstrap_gate(pointer, 1, 2, 3, 4, 5, 6, 7, 8) == pointer + 36);
    assert(!strcmp((char *)input + 0x21, "127.0.0.1"));
    uint32_t mode; uint16_t port;
    memcpy(&mode, input + 0x39, 4); memcpy(&port, input + 0x9d1, 2);
    assert(mode == 6 && port == 49152);
    for (size_t i = 0; i < sizeof(input); i++)
        if (!(i >= 0x21 && i < 0x3d) && !(i >= 0x9d1 && i < 0x9d3)) assert(input[i] == before[i]);
    assert(!dm_net_remote_start_requested(g) && !dm_net_remote_connect_requested(g));
    assert(dm_net_remote_prepare_start(g, "other", 4000) == DM_NET_BUSY);
    memcpy(before, input, sizeof(input));
    assert(dm_net_test_bootstrap_gate(pointer, 1, 2, 3, 4, 5, 6, 7, 8) == 0);
    assert(dm_net_remote_error(g) == DM_NET_INVALID && !memcmp(input, before, sizeof(input)));
    assert(!dm_net_remote_detach(g));
    for (int invalid = 0; invalid < 5; invalid++) {
        memset(input, 0xa5, sizeof(input)); memset(input + 0x39, 0, 4);
        if (invalid == 2) input[0x39] = 3;
        memcpy(before, input, sizeof(input));
        uint64_t next = dm_net_remote_attach(0x1234); assert(next && next != g);
        assert(dm_net_remote_prepare_start(g, "127.0.0.1", 4000) == DM_NET_STALE);
        if (invalid != 0) assert(!dm_net_remote_prepare_start(next, "127.0.0.1", 4000));
        if (invalid == 4) assert(dm_net_remote_start(0x1234));
        if (invalid == 1) assert(dm_net_remote_apply_start(0x1234, input, DM_NET_STARTUP_BYTES - 1) == DM_NET_INVALID);
        else if (invalid == 3) assert(dm_net_remote_apply_start(0x1234, NULL, DM_NET_STARTUP_BYTES) == DM_NET_INVALID);
        else assert(dm_net_test_bootstrap_gate(pointer, 1, 2, 3, 4, 5, 6, 7, 8) == 0);
        assert(dm_net_remote_error(next) == DM_NET_INVALID && !memcmp(input, before, sizeof(input)));
        assert(!dm_net_remote_detach(next)); g = next;
    }
    start_gate = 0;
}

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
    bootstrap_tests();
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
    assert(dm_net_test_connect_gate(0x1234, 1, 2, 3, 4, 5, 6, 7, 8) == 0x1258);
    start_gate = 1;
    assert(dm_net_test_start_gate(0x1234, 1, 2, 3, 4, 5, 6, 7, 8) == 0x1258);
    start_gate = 0;
    _Alignas(8) unsigned char client[0x300] = {0};
    regs[0] = (uintptr_t)client;
    svc_net_client_status(regs, (uintptr_t)dm_net_test_connected_body, 0);
    assert(regs[0] == 7);
    for (unsigned flag = 0; flag <= 1; flag++) {
        client[0x2f0] = flag;
        for (uint32_t mode = 0; mode <= 3; mode++) {
            memcpy(client + 0x14, &mode, 4);
            regs[0] = (uintptr_t)client;
            svc_net_client_status(regs, (uintptr_t)dm_net_test_failed_body, 1);
            assert(regs[0] == (flag || !mode));
            regs[0] = (uintptr_t)client;
            svc_net_client_close(regs, (uintptr_t)dm_net_test_hard_close_body, 0);
            assert(regs[0] == (mode == 1));
            regs[0] = (uintptr_t)client;
            svc_net_client_idle(regs, (uintptr_t)dm_net_test_hard_close_body);
            assert(regs[0] == (mode == 1));
        }
    }
    regs[0] = (uintptr_t)client;
    svc_net_client_close(regs, (uintptr_t)dm_net_test_graceful_close_body, 1);
    assert(regs[0] == 0x42);
    uint64_t generation = dm_net_remote_attach(0x1234);
    assert(generation && !dm_net_remote_attach(0x5678));
    assert(dm_net_remote_connect_requested(generation) == 0);
    assert(dm_net_remote_start_requested(generation) == 0);
    regs[0] = 0x1234; svc_net_client_idle(regs, 0); assert(regs[0] == 1);
    start_gate = 1;
    assert(dm_net_test_start_gate(0x1234, 1, 2, 3, 4, 5, 6, 7, 8) == 0x1234);
    assert(dm_net_remote_start_requested(generation) == 1);
    start_gate = 0;
    int connected = -1, failed = -1;
    assert(!dm_net_remote_status(0x5678, &connected, &failed) && connected == -1 && failed == -1);
    assert(dm_net_remote_status(0x1234, &connected, &failed) && !connected && !failed);
    assert(!dm_net_remote_activate(generation));
    // The original remote frontend waits for start to become connected before
    // it can progress. A later connect method is not required for this path.
    assert(dm_net_remote_status(0x1234, &connected, &failed) && connected && !failed);
    assert(dm_net_test_connect_gate(0x1234, 1, 2, 3, 4, 5, 6, 7, 8) == 0x1234);
    assert(dm_net_remote_connect_requested(generation) == 1);
    assert(dm_net_remote_status(0x1234, &connected, &failed) && connected && !failed);
    regs[0] = 0x1234; svc_net_client_idle(regs, 0); assert(regs[0] == 0);
    regs[0] = 0x1234; svc_net_client_status(regs, 0, 0); assert(regs[0] == 1);
    regs[0] = 0x1234; svc_net_client_status(regs, 0, 1); assert(regs[0] == 0);
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
    assert(dm_net_remote_status(0x1234, &connected, &failed) && !connected && failed);
    regs[0] = 0x1234; svc_net_client_idle(regs, 0); assert(regs[0] == 0);
    assert(dm_net_remote_activate(generation) == DM_NET_CLOSED);
    regs[0] = 0x1234; svc_net_client_status(regs, 0, 0); assert(regs[0] == 0);
    regs[0] = 0x1234; svc_net_client_status(regs, 0, 1); assert(regs[0] == 1);
    assert(dm_net_test_connect_gate(0x1234, 1, 2, 3, 4, 5, 6, 7, 8) == 0x1234);
    assert(dm_net_remote_error(generation) == DM_NET_CLOSED);
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
    assert(dm_net_remote_activate(generation) == DM_NET_STALE);
    assert(dm_net_remote_fail(generation, DM_NET_INVALID) == DM_NET_STALE);
    assert(dm_net_remote_connect_requested(next) == 0);
    assert(dm_net_remote_start_requested(next) == 0);
    assert(dm_net_remote_start_requested(generation) == DM_NET_STALE);
    for (int i = 0; i < 1024; i++) assert(!dm_net_remote_feed(next, DM_NET_SYSTEM, packet, 1));
    assert(dm_net_remote_feed(next, DM_NET_SYSTEM, packet, 1) == DM_NET_FULL);
    assert(dm_net_remote_error(next) == DM_NET_FULL);
    assert(!dm_net_remote_close(next) && dm_net_remote_error(next) == DM_NET_FULL);
    assert(!dm_net_remote_detach(next));
    for (int graceful = 0; graceful <= 1; graceful++) {
        next = dm_net_remote_attach(0x1234); assert(next);
        assert(dm_net_remote_connect(0x1234));
        assert(!dm_net_remote_activate(next));
        regs[0] = 0x1234; svc_net_client_close(regs, 0, graceful);
        assert(dm_net_remote_error(next) == DM_NET_CLOSED);
        assert(dm_net_remote_status(0x1234, &connected, &failed) && !connected && failed);
        assert(!dm_net_remote_detach(next));
    }
    next = dm_net_remote_attach(0x1234); assert(next);
    assert(dm_net_remote_fail(next, DM_NET_EMPTY) == DM_NET_INVALID);
    assert(!dm_net_remote_error(next));
    assert(!dm_net_remote_fail(next, DM_NET_INVALID));
    assert(dm_net_remote_error(next) == DM_NET_INVALID);
    assert(!dm_net_remote_detach(next));
    // Readiness may precede or follow either original request. With no request
    // it must never report a connection, and failures cannot be reactivated.
    for (int start = 0; start <= 1; start++) {
        for (int ready_first = 0; ready_first <= 1; ready_first++) {
            next = dm_net_remote_attach(0x1234); assert(next);
            assert(!dm_net_remote_start_requested(next));
            assert(!dm_net_remote_connect_requested(next));
            if (ready_first) assert(!dm_net_remote_activate(next));
            assert(dm_net_remote_status(0x1234, &connected, &failed) && !connected && !failed);
            assert(start ? dm_net_remote_start(0x1234) : dm_net_remote_connect(0x1234));
            assert(dm_net_remote_status(0x1234, &connected, &failed) && connected == ready_first && !failed);
            assert(!dm_net_remote_activate(next));
            assert(dm_net_remote_status(0x1234, &connected, &failed) && connected && !failed);
            assert(dm_net_remote_start_requested(next) == start);
            assert(dm_net_remote_connect_requested(next) == !start);
            assert(!dm_net_remote_fail(next, DM_NET_INVALID));
            assert(dm_net_remote_activate(next) == DM_NET_INVALID);
            assert(start ? dm_net_remote_start(0x1234) : dm_net_remote_connect(0x1234));
            assert(dm_net_remote_status(0x1234, &connected, &failed) && !connected && failed);
            assert(!dm_net_remote_detach(next));
        }
    }
    puts("ARM64 engine shims passed: queues, lifecycle/status, no local fallback, start/connect gates with ninth argument, stale generations and overflow disconnect.");
    return 0;
}
