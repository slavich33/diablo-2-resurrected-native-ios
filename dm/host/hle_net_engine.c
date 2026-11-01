// Native client packet-pump boundary for Switch build 3.3.94012.
// Unbound queue-entry cuts resume the original methods. Bound clients exchange
// complete packets through hle_net_binding.c. The receive
// method has an indirect result in x8; an ordinary C function call loses that
// argument. Keep it explicitly, as in dm_dropfilter.c's guest-call shim.
#include "dm_net_engine.h"
#include "dm_net_binding.h"
#include "dm_save_completion.h"
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <stddef.h>

static pthread_once_t trace_once = PTHREAD_ONCE_INIT;
static pthread_mutex_t trace_lock = PTHREAD_MUTEX_INITIALIZER;
static FILE *trace_file;
static unsigned long long trace_sequence;

static void trace_init(void) {
    const char *path = getenv("DM_NET_ENGINE_TRACE");
    if (path && *path) trace_file = fopen(path, "a");
}

static void trace_span(const char *direction, const uint64_t *span) {
    pthread_once(&trace_once, trace_init);
    if (!trace_file || !span) return;
    uint64_t begin = span[0], end = span[1];
    if (!begin || end <= begin || end - begin > 65536) return;
    // Only opcode/length are recorded: no account, character, token or payload.
    unsigned opcode = *(const unsigned char *)(uintptr_t)begin;
    pthread_mutex_lock(&trace_lock);
    fprintf(trace_file, "{\"sequence\":%llu,\"direction\":\"%s\",\"id\":%u,\"length\":%llu}\n",
            ++trace_sequence, direction, opcode, (unsigned long long)(end - begin));
    fflush(trace_file);
    pthread_mutex_unlock(&trace_lock);
}

static void forward_virtual(uint64_t *regs, uint64_t target) {
#if defined(__aarch64__)
    register uint64_t x0 __asm__("x0") = regs[0];
    register uint64_t x1 __asm__("x1") = regs[1];
    register uint64_t x8 __asm__("x8") = regs[8];
    register uint64_t x16 __asm__("x16") = target;
    __asm__ volatile("blr x16"
        : "+r"(x0), "+r"(x1), "+r"(x8), "+r"(x16)
        :
        : "x2", "x3", "x4", "x5", "x6", "x7", "x9", "x10", "x11", "x12",
          "x13", "x14", "x15", "x17", "x30",
          "v0", "v1", "v2", "v3", "v4", "v5", "v6", "v7",
          "v16", "v17", "v18", "v19", "v20", "v21", "v22", "v23", "v24",
          "v25", "v26", "v27", "v28", "v29", "v30", "v31", "cc", "memory");
    regs[0] = x0;
#else
#error Native game-engine hooks require ARM64 and the Horizon indirect-result ABI
#endif
}

void svc_net_client_send(uint64_t *regs) {
    // main+0x2cec94: blr x8, x0=client object, x1={begin,end}.
    trace_span("c2s", (const uint64_t *)(uintptr_t)regs[1]);
    forward_virtual(regs, regs[8]);
}

extern void dm_net_resume_poll(void);
extern void dm_net_resume_send(void);
extern void dm_net_resume_connected(void);
extern void dm_net_resume_failed(void);
extern void dm_net_resume_hard_close(void);
extern void dm_net_resume_graceful_close(void);

static void forward_entry(uint64_t *regs, uint64_t body, void (*resume)(void)) {
#if defined(__aarch64__)
    register uint64_t x0 __asm__("x0") = regs[0];
    register uint64_t x1 __asm__("x1") = regs[1];
    register uint64_t x8 __asm__("x8") = regs[8];
    register uint64_t x16 __asm__("x16") = body;
    register uint64_t x17 __asm__("x17") = (uintptr_t)resume;
    __asm__ volatile("blr x17"
        : "+r"(x0), "+r"(x1), "+r"(x8), "+r"(x16), "+r"(x17)
        :
        : "x2", "x3", "x4", "x5", "x6", "x7", "x9", "x10", "x11", "x12",
          "x13", "x14", "x15", "x30",
          "v0", "v1", "v2", "v3", "v4", "v5", "v6", "v7",
          "v16", "v17", "v18", "v19", "v20", "v21", "v22", "v23", "v24",
          "v25", "v26", "v27", "v28", "v29", "v30", "v31", "cc", "memory");
    regs[0] = x0;
#endif
}

void svc_net_queue_send(uint64_t *regs, uint64_t original_body) {
    trace_span("c2s", (const uint64_t *)(uintptr_t)regs[1]);
    if (dm_net_remote_send(regs[0], (const uint64_t *)(uintptr_t)regs[1])) { regs[0] = 0; return; }
    forward_entry(regs, original_body, dm_net_resume_send);
}

void svc_net_queue_poll(uint64_t *regs, uint64_t original_body, int gameplay) {
    const unsigned char *result = (const unsigned char *)(uintptr_t)regs[8];
    if (dm_net_remote_poll(regs[0], gameplay ? DM_NET_GAMEPLAY : DM_NET_SYSTEM,
                           (uint64_t *)(uintptr_t)regs[1], (void *)(uintptr_t)regs[8])) regs[0] = 0;
    else forward_entry(regs, original_body, dm_net_resume_poll);
    if (result && result[16]) trace_span(gameplay ? "s2c-game" : "s2c-system", (const uint64_t *)result);
}

void svc_net_client_status(uint64_t *regs, uint64_t original_body, int failed) {
    int connected = 0, failure = 0;
    if (dm_net_remote_status(regs[0], &connected, &failure)) regs[0] = failed ? failure : connected;
    else forward_entry(regs, original_body, failed ? dm_net_resume_failed : dm_net_resume_connected);
}

void svc_net_client_close(uint64_t *regs, uint64_t original_body, int graceful) {
    if (dm_net_remote_disconnect(regs[0])) { regs[0] = 0; return; }
    forward_entry(regs, original_body, graceful ? dm_net_resume_graceful_close : dm_net_resume_hard_close);
}

void svc_net_connect_guard(uint64_t *regs) {
    regs[8] = dm_net_remote_connect(regs[0]) ? 1 : 0;
}
void svc_net_start_guard(uint64_t *regs) {
    regs[8] = dm_net_remote_start(regs[0]) ? 1 : 0;
}
void svc_net_bootstrap_guard(uint64_t *regs, uint64_t client) {
    int result = dm_net_remote_apply_start(client, (void *)(uintptr_t)regs[0], DM_NET_STARTUP_BYTES);
    // Success resumes the original startup with its prepared input; a bound
    // failure returns false before local world/backend initialization.
    regs[8] = result < 0 ? 1 : 0;
    if (result < 0) regs[0] = 0;
}
void svc_net_client_idle(uint64_t *regs, uint64_t original_body) {
    int can_connect = 0;
    if (dm_net_remote_can_connect(regs[0], &can_connect)) regs[0] = can_connect;
    // Identical displaced instructions to hard close: ldr w8,[x0,#0x14];cmp w8,#1.
    else forward_entry(regs, original_body, dm_net_resume_hard_close);
}

void svc_net_session_poll(uint64_t *regs, uint64_t original_target, uint64_t client) {
    int connected = 0, failed = 0;
    if (dm_net_remote_status(client, &connected, &failed)) {
        regs[0] = connected && !failed && dm_online_save_isolated() == 1;
        return;
    }
    regs[0] = ((uint32_t (*)(uint64_t))(uintptr_t)original_target)(regs[0]);
}

void svc_net_client_poll(uint64_t *regs) {
    // main+0x2cfa5c: blr x9, x0=client, x1=u64 queue cursor,
    // x8=optional span output {begin,end,present:u8,padding} (24 bytes).
    const unsigned char *result = (const unsigned char *)(uintptr_t)regs[8];
    forward_virtual(regs, regs[9]);
    if (result && result[16]) trace_span("s2c", (const uint64_t *)result);
}
