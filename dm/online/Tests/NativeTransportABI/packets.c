#include "OnlineTransport.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static int32_t resolve(void *context, const uint8_t *header, uint32_t available) {
    assert(available > 0 && available <= 512);
    *(int *)context += 1;
    return header[0] == 0x10 ? 4 : -1;  // synthetic fixture, not a game table
}

int main(void) {
    const uint8_t control[] = {0xd0,22,0,'D','2','R','L',1,7,0,0,0,0,0,0,0,0,0,0,4,0,1,2,3,4};
    const uint8_t stock[] = {0x10,1,2,3};
    uint8_t out[256]; int calls = 0; int32_t kind = 99;
    assert(dm_online_packets_read(NULL, out, sizeof(out), &kind) == -4 && kind == 0);
    kind = 99;
    assert(dm_online_packets_read(NULL, out, 0, &kind) == -4 && kind == 0);
    assert(!dm_online_packets_open(NULL, NULL));
    void *handle = dm_online_packets_open(resolve, &calls); assert(handle);
    assert(dm_online_packets_append(handle, control, 3) == 0);
    assert(dm_online_packets_read(handle, out, sizeof(out), &kind) == -1 && kind == 0);
    assert(dm_online_packets_append(handle, control + 3, sizeof(control) - 3) == 0);
    assert(dm_online_packets_append(handle, stock, sizeof(stock)) == 0);
    assert(dm_online_packets_end(handle) == 0);
    assert(dm_online_packets_read(handle, out, 1, &kind) == -5 && kind == 0);
    assert(dm_online_packets_read(handle, out, sizeof(out), &kind) == sizeof(control));
    assert(kind == 2 && memcmp(out, control, sizeof(control)) == 0 && calls == 0);
    assert(dm_online_packets_read(handle, out, sizeof(out), &kind) == sizeof(stock));
    assert(kind == 1 && memcmp(out, stock, sizeof(stock)) == 0 && calls == 1);
    assert(dm_online_packets_read(handle, out, sizeof(out), &kind) == -2 && kind == 0);
    assert(dm_online_packets_append(handle, stock, sizeof(stock)) == -2);
    assert(dm_online_packets_error(handle) == 0);
    dm_online_packets_release(handle);

    handle = dm_online_packets_open(resolve, &calls); assert(handle);
    assert(dm_online_packets_append(handle, control, 2) == 0);
    assert(dm_online_packets_end(handle) == 0);
    assert(dm_online_packets_read(handle, out, sizeof(out), &kind) == -3);
    assert(dm_online_packets_error(handle) == 3);
    assert(dm_online_packets_read(handle, out, sizeof(out), &kind) == -3);
    dm_online_packets_release(handle);
    puts("C packet ABI: callbacks, split input, retained retry, ordered drain and truncated EOF passed.");
    return 0;
}
