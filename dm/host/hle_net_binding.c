#include "dm_net_binding.h"
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

enum { MAX_PACKET = 65536, MAX_BYTES = 262144, MAX_PACKETS = 1024 };
typedef struct packet { struct packet *next; uint32_t count; unsigned char bytes[]; } packet;
typedef struct { packet *first, *last; uint32_t bytes, count; } queue;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static struct {
    uint64_t client, generation, next_generation;
    int failure, active, connect_requested, start_requested;
    queue incoming[2], outgoing;
    packet *held[2];
} state;

static void clear(queue *q) {
    while (q->first) { packet *p = q->first; q->first = p->next; free(p); }
    memset(q, 0, sizeof(*q));
}
static packet *take(queue *q) {
    packet *p = q->first;
    if (p) {
        q->first = p->next; if (!q->first) q->last = NULL;
        q->bytes -= p->count; q->count--; p->next = NULL;
    }
    return p;
}
static int append(queue *q, const void *bytes, uint32_t count) {
    if (!bytes || !count || count > MAX_PACKET) return DM_NET_INVALID;
    if (q->count == MAX_PACKETS || count > MAX_BYTES - q->bytes) return DM_NET_FULL;
    packet *p = malloc(sizeof(*p) + count);
    if (!p) return DM_NET_FULL;
    p->next = NULL; p->count = count; memcpy(p->bytes, bytes, count);
    if (q->last) q->last->next = p; else q->first = p;
    q->last = p; q->count++; q->bytes += count;
    return 0;
}
static int current(uint64_t generation) {
    if (!generation || generation != state.generation) return DM_NET_STALE;
    return state.failure;
}
static void fail(int reason) {
    if (!state.failure) state.failure = reason;
    state.active = 0;
    clear(&state.incoming[0]); clear(&state.incoming[1]); clear(&state.outgoing);
    // Borrowed spans are retained until their consumer's next poll. Network
    // close may run concurrently with the engine parsing the previous packet.
}

uint64_t dm_net_remote_attach(uint64_t client) {
    if (!client) return 0;
    pthread_mutex_lock(&lock);
    uint64_t result = 0;
    if (!state.generation) {
        if (!++state.next_generation) ++state.next_generation;
        state.client = client; state.generation = state.next_generation; state.failure = 0;
        state.active = state.connect_requested = state.start_requested = 0;
        result = state.generation;
    }
    pthread_mutex_unlock(&lock);
    return result;
}
int dm_net_remote_feed(uint64_t generation, int channel, const void *bytes, uint32_t count) {
    if (channel != DM_NET_SYSTEM && channel != DM_NET_GAMEPLAY) return DM_NET_INVALID;
    pthread_mutex_lock(&lock);
    int result = current(generation);
    if (!result) {
        result = append(&state.incoming[channel], bytes, count);
        if (result) fail(result);
    }
    pthread_mutex_unlock(&lock);
    return result;
}
int dm_net_remote_read(uint64_t generation, void *bytes, uint32_t capacity) {
    if (!bytes || !capacity) return DM_NET_INVALID;
    pthread_mutex_lock(&lock);
    int result = current(generation);
    if (!result) {
        packet *p = state.outgoing.first;
        if (!p) result = DM_NET_EMPTY;
        else if (p->count > capacity) result = DM_NET_SHORT;
        else { p = take(&state.outgoing); memcpy(bytes, p->bytes, p->count); result = (int)p->count; free(p); }
    }
    pthread_mutex_unlock(&lock);
    return result;
}
int dm_net_remote_error(uint64_t generation) {
    pthread_mutex_lock(&lock); int result = current(generation); pthread_mutex_unlock(&lock);
    return result;
}
int dm_net_remote_activate(uint64_t generation) {
    pthread_mutex_lock(&lock);
    int result = current(generation);
    if (!result) state.active = 1;
    pthread_mutex_unlock(&lock);
    return result;
}
int dm_net_remote_connect_requested(uint64_t generation) {
    pthread_mutex_lock(&lock);
    int result = current(generation);
    if (!result) result = state.connect_requested;
    pthread_mutex_unlock(&lock);
    return result;
}
int dm_net_remote_start_requested(uint64_t generation) {
    pthread_mutex_lock(&lock);
    int result = current(generation);
    if (!result) result = state.start_requested;
    pthread_mutex_unlock(&lock);
    return result;
}
int dm_net_remote_fail(uint64_t generation, int reason) {
    if (reason != DM_NET_CLOSED && reason != DM_NET_INVALID && reason != DM_NET_FULL) return DM_NET_INVALID;
    pthread_mutex_lock(&lock);
    int result = current(generation);
    if (result != DM_NET_STALE) { fail(reason); result = 0; }
    pthread_mutex_unlock(&lock);
    return result;
}
int dm_net_remote_close(uint64_t generation) {
    return dm_net_remote_fail(generation, DM_NET_CLOSED);
}
int dm_net_remote_detach(uint64_t generation) {
    pthread_mutex_lock(&lock);
    int result = current(generation);
    if (result != DM_NET_STALE) {
        fail(DM_NET_CLOSED);
        free(state.held[0]); free(state.held[1]); state.held[0] = state.held[1] = NULL;
        state.client = state.generation = 0; result = 0;
    }
    pthread_mutex_unlock(&lock);
    return result;
}
int dm_net_remote_send(uint64_t client, const uint64_t *span) {
    pthread_mutex_lock(&lock);
    int bound = state.generation && client == state.client;
    if (bound && !state.failure) {
        if (!span || !span[0] || span[1] <= span[0] || span[1] - span[0] > MAX_PACKET) fail(DM_NET_INVALID);
        else {
            int result = append(&state.outgoing, (const void *)(uintptr_t)span[0], (uint32_t)(span[1] - span[0]));
            if (result) fail(result);
        }
    }
    pthread_mutex_unlock(&lock);
    return bound;
}
int dm_net_remote_connect(uint64_t client) {
    pthread_mutex_lock(&lock);
    int bound = state.generation && client == state.client;
    // Repeated calls cannot reopen a terminated binding or reset its queues.
    if (bound && !state.failure) state.connect_requested = 1;
    pthread_mutex_unlock(&lock);
    return bound;
}
int dm_net_remote_start(uint64_t client) {
    pthread_mutex_lock(&lock);
    int bound = state.generation && client == state.client;
    if (bound && !state.failure) state.start_requested = 1;
    pthread_mutex_unlock(&lock);
    return bound;
}
int dm_net_remote_can_connect(uint64_t client, int *result) {
    pthread_mutex_lock(&lock);
    int bound = state.generation && client == state.client;
    if (bound && result) *result = !state.failure && !state.connect_requested;
    pthread_mutex_unlock(&lock);
    return bound;
}
int dm_net_remote_status(uint64_t client, int *connected, int *failed) {
    pthread_mutex_lock(&lock);
    int bound = state.generation && client == state.client;
    if (bound) {
        // Both original entry points can establish a backend connection. The
        // frontend start path waits on connected before reaching any later
        // connect call; requiring connect_requested here would deadlock it.
        // Neither request is sufficient without explicit packet-pump readiness.
        if (connected) *connected = !state.failure && state.active &&
            (state.connect_requested || state.start_requested);
        if (failed) *failed = !!state.failure;
    }
    pthread_mutex_unlock(&lock);
    return bound;
}
int dm_net_remote_disconnect(uint64_t client) {
    pthread_mutex_lock(&lock);
    int bound = state.generation && client == state.client;
    if (bound) fail(DM_NET_CLOSED);
    pthread_mutex_unlock(&lock);
    return bound;
}
int dm_net_remote_poll(uint64_t client, int channel, uint64_t *cursor, void *optional_span) {
    if (channel != DM_NET_SYSTEM && channel != DM_NET_GAMEPLAY) return 0;
    pthread_mutex_lock(&lock);
    int bound = state.generation && client == state.client;
    if (bound) {
        unsigned char *out = optional_span;
        if (!out || !cursor) fail(DM_NET_INVALID);
        else {
            free(state.held[channel]); state.held[channel] = NULL;
            *cursor = 0; out[16] = 0;
            if (!state.failure) {
                packet *p = take(&state.incoming[channel]); state.held[channel] = p;
                if (p) {
                    uint64_t span[] = {(uintptr_t)p->bytes, (uintptr_t)(p->bytes + p->count)};
                    memcpy(out, span, sizeof(span)); out[16] = 1;
                }
            }
        }
    }
    pthread_mutex_unlock(&lock);
    return bound;
}
