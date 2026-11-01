#include "../dm.h"
#include "../dm_net_tables.h"
#include <assert.h>
#include <pthread.h>
#include <errno.h>
#include <time.h>

module_t g_mod[MAX_MOD];
int g_nmod = 1;
static int gate_present;
static void (*observer)(const uint64_t *);
int gate_obs_present(int id) { assert(id == OBS_NET_ITEMSTATCOST); return gate_present; }
void gate_obs_set(int id, void (*fn)(const uint64_t *)) { assert(id == OBS_NET_ITEMSTATCOST); observer = fn; }
typedef struct { pthread_mutex_t lock; pthread_cond_t condition; int started, done; const uint64_t *regs; } reload_job;
static void *reload_worker(void *context) {
    reload_job *job = context;
    assert(dm_net_itemstatcost_unpin() == DM_NET_TABLE_INVALID); // A different thread cannot release the pin.
    pthread_mutex_lock(&job->lock); job->started = 1; pthread_cond_signal(&job->condition); pthread_mutex_unlock(&job->lock);
    observer(job->regs);
    pthread_mutex_lock(&job->lock); job->done = 1; pthread_cond_signal(&job->condition); pthread_mutex_unlock(&job->lock);
    return NULL;
}

int main(void) {
    dm_net_itemstatcost_info info;
    unsigned char out[648], source[648];
    memset(source, 0xa3, sizeof source);
    memset(out, 0x7b, sizeof out);
    assert(dm_net_itemstatcost_copy(0, 0, NULL, 0, &info) == DM_NET_TABLE_INVALID);
    assert(dm_net_itemstatcost_copy(4, 0, NULL, 0, &info) == DM_NET_TABLE_INVALID);
    assert(dm_net_itemstatcost_copy(1, 0, NULL, 1, &info) == DM_NET_TABLE_INVALID);
    assert(dm_net_itemstatcost_copy(1, 0, NULL, 0, NULL) == DM_NET_TABLE_INVALID);
    assert(dm_net_itemstatcost_copy(1, 0, NULL, 0, &info) == DM_NET_TABLE_UNAVAILABLE);
    dm_net_tables_install(); assert(!observer);
    gate_present = 1; dm_net_tables_install(); assert(observer);
    strcpy(g_mod[0].name, "main"); g_mod[0].size = 0x2d65000;
    g_mod[0].base = calloc(1, g_mod[0].size); assert(g_mod[0].base);
    uint64_t *manager = calloc(1, 0x2000); assert(manager);
    uint64_t linker[8] = {0}, heads[2] = {0}, nodes[2][7] = {{0}};
    linker[3] = 2; linker[4] = (uintptr_t)heads; linker[5] = 2;
    nodes[0][0] = (uintptr_t)nodes[1]; nodes[0][1] = (uintptr_t)&nodes[0][4];
    nodes[0][2] = 8; nodes[0][3] = (UINT64_C(1) << 63) | 15;
    memcpy(&nodes[0][4], "strength", 8); nodes[0][6] = 0;
    nodes[1][1] = (uintptr_t)"synthetic-long-stat-name";
    nodes[1][2] = 24; nodes[1][3] = 24; nodes[1][6] = 1;
    heads[0] = (uintptr_t)nodes[0];
    manager[0x12a8 / 8] = (uintptr_t)linker;
    uint64_t regs[100], before[100];
    for (unsigned e = 1; e <= 3; ++e) {
        memcpy(g_mod[0].base + 0x2d64a18 + 16 * e, &(uint64_t){(uintptr_t)manager}, 8);
        for (unsigned n = 0; n < 100; ++n) regs[n] = 0xbabacafe00 + n;
        regs[23] = (uintptr_t)manager; memcpy(before, regs, sizeof regs);
        manager[0x1290 / 8] = (uintptr_t)source;
        manager[0x1298 / 8] = 2;
        manager[0x12a0 / 8] = (UINT64_C(1) << 63) | 2;
        observer(regs); assert(!memcmp(regs, before, sizeof regs));
        assert(dm_net_itemstatcost_copy(e, 0, NULL, 0, &info) == DM_NET_TABLE_READY);
        assert(info.edition == e && info.row_count == 2 && info.row_bytes == 324 && info.generation == 1);
        assert(info.resolved_names == 2);
        uint64_t generation = info.generation;
        size_t required = 0; char name[64]; memset(name, 0x7b, sizeof name);
        assert(dm_net_itemstatcost_name(e, generation, 0, NULL, 0, &required) == DM_NET_TABLE_READY && required == 9);
        assert(dm_net_itemstatcost_name(e, generation, 0, name, required - 1, &required) == DM_NET_TABLE_CAPACITY && name[0] == 0x7b);
        assert(dm_net_itemstatcost_name(e, generation, 0, name, sizeof name, &required) == DM_NET_TABLE_READY && !strcmp(name, "strength"));
        assert(dm_net_itemstatcost_name(e, generation, 1, name, sizeof name, &required) == DM_NET_TABLE_READY && !strcmp(name, "synthetic-long-stat-name"));
        assert(dm_net_itemstatcost_name(e, generation, 2, name, sizeof name, &required) == DM_NET_TABLE_UNAVAILABLE);
        assert(dm_net_itemstatcost_copy(e, 0, out, sizeof out, &info) == DM_NET_TABLE_INVALID);
        assert(dm_net_itemstatcost_copy(e, generation, out, sizeof out - 1, &info) == DM_NET_TABLE_CAPACITY);
        assert(out[0] == 0x7b && out[647] == 0x7b);
        source[0] = 0x64;
        assert(dm_net_itemstatcost_copy(e, generation, out, sizeof out, &info) == DM_NET_TABLE_READY);
        assert(out[0] == 0xa3 && out[647] == 0xa3); // Own copy, not the live pointer.
        observer(regs);
        memset(out, 0x7b, sizeof out);
        assert(dm_net_itemstatcost_copy(e, generation, out, sizeof out, &info) == DM_NET_TABLE_STALE);
        assert(info.generation == generation + 1 && out[0] == 0x7b && out[647] == 0x7b);
        assert(dm_net_itemstatcost_name(e, generation, 0, name, sizeof name, &required) == DM_NET_TABLE_STALE && !required);
        assert(dm_net_itemstatcost_copy(e, info.generation, out, sizeof out, &info) == DM_NET_TABLE_READY);
        assert(out[0] == 0x64);
        uint64_t pinned_generation = info.generation;
        assert(dm_net_itemstatcost_pin(e, 0) == DM_NET_TABLE_INVALID);
        assert(dm_net_itemstatcost_pin(e, pinned_generation - 1) == DM_NET_TABLE_STALE);
        assert(dm_net_itemstatcost_pin(e, pinned_generation) == DM_NET_TABLE_READY);
        assert(dm_net_itemstatcost_pin(e, pinned_generation) == DM_NET_TABLE_INVALID);
        assert(dm_net_itemstatcost_copy(e, 0, NULL, 0, &info) == DM_NET_TABLE_INVALID);
        assert(dm_net_itemstatcost_name(e, pinned_generation, 0, name, sizeof name, &required) == DM_NET_TABLE_INVALID);
        reload_job job = {.lock = PTHREAD_MUTEX_INITIALIZER, .condition = PTHREAD_COND_INITIALIZER, .regs = regs};
        pthread_t worker; assert(!pthread_create(&worker, NULL, reload_worker, &job));
        pthread_mutex_lock(&job.lock);
        while (!job.started) pthread_cond_wait(&job.condition, &job.lock);
        struct timespec deadline; assert(!clock_gettime(CLOCK_REALTIME, &deadline));
        deadline.tv_nsec += 25000000; if (deadline.tv_nsec >= 1000000000) { deadline.tv_sec++; deadline.tv_nsec -= 1000000000; }
        int wait_result = 0;
        while (!job.done && !wait_result) wait_result = pthread_cond_timedwait(&job.condition, &job.lock, &deadline);
        assert(!job.done && wait_result == ETIMEDOUT);
        pthread_mutex_unlock(&job.lock);
        assert(dm_net_itemstatcost_unpin() == DM_NET_TABLE_READY);
        assert(dm_net_itemstatcost_unpin() == DM_NET_TABLE_INVALID);
        assert(!pthread_join(worker, NULL));
        pthread_cond_destroy(&job.condition); pthread_mutex_destroy(&job.lock);
        assert(dm_net_itemstatcost_copy(e, 0, NULL, 0, &info) == DM_NET_TABLE_READY && info.generation == pinned_generation + 1);
        assert(dm_net_itemstatcost_pin(e, pinned_generation) == DM_NET_TABLE_STALE);
        // A failed reload invalidates the old successful data, including an
        // unreadable pointer, oversized/empty rows, and count > capacity.
        for (unsigned failure = 0; failure < 4; ++failure) {
            manager[0x1290 / 8] = failure == 0 ? 4096 : (uintptr_t)source;
            manager[0x1298 / 8] = failure == 1 ? 32769 : failure == 2 ? 0 : 2;
            manager[0x12a0 / 8] = failure == 3 ? 1 : 32769;
            observer(regs);
            memset(out, 0x7b, sizeof out);
            assert(dm_net_itemstatcost_copy(e, 0, NULL, 0, &info) == DM_NET_TABLE_CAPTURE_FAILED);
            assert(dm_net_itemstatcost_copy(e, info.generation, out, sizeof out, &info) == DM_NET_TABLE_CAPTURE_FAILED);
            assert(!info.row_count && out[0] == 0x7b && out[647] == 0x7b);
        }
        manager[0x1290 / 8] = (uintptr_t)source;
        manager[0x1298 / 8] = manager[0x12a0 / 8] = 2;
        // A malformed linker must never silently keep names from an older mod.
        for (unsigned bad_linker = 0; bad_linker < 5; ++bad_linker) {
            linker[3] = bad_linker == 0 ? 3 : 2;
            linker[5] = bad_linker == 4 ? 0 : 2;
            nodes[1][0] = bad_linker == 1 ? (uintptr_t)nodes[0] : 0;
            nodes[1][6] = bad_linker == 2 ? 0 : 1;
            nodes[1][2] = bad_linker == 3 ? 1025 : 24;
            observer(regs);
            assert(dm_net_itemstatcost_copy(e, 0, NULL, 0, &info) == DM_NET_TABLE_READY && !info.resolved_names);
            assert(dm_net_itemstatcost_name(e, info.generation, 0, name, sizeof name, &required) == DM_NET_TABLE_CAPTURE_FAILED);
        }
        linker[3] = linker[5] = 2; nodes[1][0] = 0; nodes[1][6] = 1; nodes[1][2] = 24;
        memset(source, 0xa3, sizeof source); memset(out, 0x7b, sizeof out);
        memset(g_mod[0].base + 0x2d64a18 + 16 * e, 0, 8);
    }
    free(manager); free(g_mod[0].base);
    puts("native table capture: edition isolation, immutable copy, pinned publication across reload, same-thread release and failed-read invalidation passed");
}
