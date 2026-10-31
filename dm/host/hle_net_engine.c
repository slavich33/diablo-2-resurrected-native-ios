// Native client packet-pump boundary for Switch build 3.3.94012.
// The optional rewriter cuts preserve the original virtual calls. The receive
// method has an indirect result in x8; an ordinary C function call loses that
// argument. Keep it explicitly, as in dm_dropfilter.c's guest-call shim.
#include "dm_net_engine.h"
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

void svc_net_client_poll(uint64_t *regs) {
    // main+0x2cfa5c: blr x9, x0=client, x1=error output,
    // x8=optional span output {begin,end,present:u8,padding} (24 bytes).
    const unsigned char *result = (const unsigned char *)(uintptr_t)regs[8];
    forward_virtual(regs, regs[9]);
    if (result && result[16]) trace_span("s2c", (const uint64_t *)result);
}
