#include "dm_net_level_allocations.h"
#include <pthread.h>
#include <stdatomic.h>
#include <stddef.h>
#include <string.h>

enum { CAPACITY=131072, MAXIMUM=65536 };
static uintptr_t entries[CAPACITY], scratch[CAPACITY];
static pthread_mutex_t lock=PTHREAD_MUTEX_INITIALIZER;
static _Atomic unsigned count;
static unsigned tombstones;

static size_t hash(uintptr_t p) {
    p >>= 4;
    p ^= p >> 30; p *= UINT64_C(0xbf58476d1ce4e5b9);
    p ^= p >> 27; p *= UINT64_C(0x94d049bb133111eb);
    return (size_t)(p ^ (p >> 31)) & (CAPACITY-1);
}
static size_t find(uintptr_t p) {
    size_t at=hash(p);
    for (size_t n=0;n<CAPACITY;n++,at=(at+1)&(CAPACITY-1))
        if (!entries[at] || entries[at]==p) return at;
    return CAPACITY;
}
static void compact(void) {
    memset(scratch,0,sizeof(scratch));
    for (size_t i=0;i<CAPACITY;i++) if (entries[i]>1) {
        size_t at=hash(entries[i]);
        while (scratch[at]) at=(at+1)&(CAPACITY-1);
        scratch[at]=entries[i];
    }
    memcpy(entries,scratch,sizeof(entries)); tombstones=0;
}

int dm_net_level_allocation_add(const void *pointer) {
    uintptr_t p=(uintptr_t)pointer;
    if (p<16 || (p & 15)) return 0;
    pthread_mutex_lock(&lock);
    if (tombstones>CAPACITY/3) compact();
    size_t at=hash(p), first=CAPACITY;
    int result=0;
    for (size_t n=0;n<CAPACITY;n++,at=(at+1)&(CAPACITY-1)) {
        if (entries[at]==p) { result=1; break; }
        if (entries[at]==1 && first==CAPACITY) first=at;
        if (!entries[at]) {
            if (atomic_load_explicit(&count,memory_order_relaxed)>=MAXIMUM) break;
            if (first!=CAPACITY) { at=first; tombstones--; }
            entries[at]=p; atomic_fetch_add_explicit(&count,1,memory_order_release); result=1; break;
        }
    }
    pthread_mutex_unlock(&lock); return result;
}

int dm_net_level_allocation_has(const void *pointer) {
    uintptr_t p=(uintptr_t)pointer;
    if (p<16 || (p & 15) || !atomic_load_explicit(&count,memory_order_acquire)) return 0;
    pthread_mutex_lock(&lock);
    size_t at=find(p); int result=at<CAPACITY && entries[at]==p;
    pthread_mutex_unlock(&lock); return result;
}

void dm_net_level_allocation_remove(const void *pointer) {
    uintptr_t p=(uintptr_t)pointer;
    if (p<16 || (p & 15) || !atomic_load_explicit(&count,memory_order_acquire)) return;
    pthread_mutex_lock(&lock);
    size_t at=find(p);
    if (at<CAPACITY && entries[at]==p) {
        entries[at]=1; tombstones++;
        if (atomic_fetch_sub_explicit(&count,1,memory_order_release)==1) {
            memset(entries,0,sizeof(entries)); tombstones=0;
        }
    }
    pthread_mutex_unlock(&lock);
}
