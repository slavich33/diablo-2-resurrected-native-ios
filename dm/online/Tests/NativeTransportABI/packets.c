#include "OnlineTransport.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

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

    // u16 carrier length includes the18-byte D2RL header: total65538 bytes.
    // Independent C construction catches truncation in Swift/C count widths.
    size_t maximum_count = 65538;
    uint8_t *maximum = calloc(maximum_count, 1), *large_out = malloc(maximum_count);
    assert(maximum && large_out);
    maximum[0] = 0xd0; maximum[1] = maximum[2] = 0xff;
    memcpy(maximum + 3, "D2RL", 4); maximum[7] = 1; maximum[8] = 3;
    maximum[19] = 0xed; maximum[20] = 0xff; // payload65517
    handle = dm_online_packets_open(resolve, &calls); assert(handle);
    assert(dm_online_packets_append(handle, maximum, 65536) == 0);
    assert(dm_online_packets_read(handle, large_out, 65536, &kind) == -1);
    assert(dm_online_packets_append(handle, maximum + 65536, 2) == 0);
    assert(dm_online_packets_read(handle, large_out, 65536, &kind) == -5 && kind == 0);
    assert(dm_online_packets_read(handle, large_out, (uint32_t)maximum_count, &kind) == (int32_t)maximum_count);
    assert(kind == 3 && !memcmp(large_out, maximum, maximum_count));
    dm_online_packets_release(handle); free(large_out); free(maximum);

    // A complete kind11 FRAGMENT is an opaque loader message, not a complete
    // gameplay command. The engine must not consume it through kind1 routing.
    const uint8_t fragment[] = {0xd0,23,0,'D','2','R','L',1,11,0,0,0,0,0,0,1,0,0,0,5,0,1,2,0,0,0x20};
    handle = dm_online_packets_open(resolve, &calls); assert(handle);
    int previous_calls = calls;
    for (size_t i = 0; i < sizeof(fragment); i++) {
        assert(dm_online_packets_append(handle, fragment + i, 1) == 0);
        if (i + 1 < sizeof(fragment)) assert(dm_online_packets_read(handle, out, sizeof(out), &kind) == -1);
    }
    assert(dm_online_packets_read(handle, out, 1, &kind) == -5 && kind == 0);
    assert(dm_online_packets_read(handle, out, sizeof(out), &kind) == sizeof(fragment));
    assert(kind == 3 && !memcmp(out, fragment, sizeof(fragment)) && calls == previous_calls);
    assert(dm_online_packets_end(handle) == 0);
    assert(dm_online_packets_read(handle, out, sizeof(out), &kind) == -2);
    dm_online_packets_release(handle);

    handle = dm_online_packets_open(resolve, &calls); assert(handle);
    assert(dm_online_packets_append(handle, control, 2) == 0);
    assert(dm_online_packets_end(handle) == 0);
    assert(dm_online_packets_read(handle, out, sizeof(out), &kind) == -3);
    assert(dm_online_packets_error(handle) == 3);
    assert(dm_online_packets_read(handle, out, sizeof(out), &kind) == -3);
    dm_online_packets_release(handle);
    // Exact-build stock entry point needs no guest callback. Exercise the
    // real 512-byte packet and prove short-output retry preserves every byte.
    uint8_t stock512[512], stock_out[512];
    memset(stock512, 0xd0, sizeof(stock512)); stock512[0] = 0x56;
    handle = dm_online_packets_open_stock_94012(); assert(handle);
    assert(dm_online_packets_append(handle, stock512, 511) == 0);
    assert(dm_online_packets_read(handle, stock_out, sizeof(stock_out), &kind) == -1);
    assert(dm_online_packets_append(handle, stock512 + 511, 1) == 0);
    assert(dm_online_packets_read(handle, stock_out, 511, &kind) == -5 && kind == 0);
    assert(dm_online_packets_read(handle, stock_out, sizeof(stock_out), &kind) == 512);
    assert(kind == 1 && !memcmp(stock512, stock_out, sizeof(stock512)));
    assert(dm_online_packets_end(handle) == 0);
    assert(dm_online_packets_read(handle, stock_out, sizeof(stock_out), &kind) == -2);
    dm_online_packets_release(handle);

    // A real variable packet cannot be sized from its TCP chunk or skipped.
    const uint8_t variable[] = {0x9c, 0, 3};
    handle = dm_online_packets_open_stock_94012(); assert(handle);
    assert(dm_online_packets_append(handle, variable, sizeof(variable)) == 0);
    assert(dm_online_packets_append(handle, control, sizeof(control)) == 0);
    assert(dm_online_packets_read(handle, out, sizeof(out), &kind) == -3 && kind == 0);
    assert(dm_online_packets_error(handle) == 1);
    assert(dm_online_packets_read(handle, out, sizeof(out), &kind) == -3);
    dm_online_packets_release(handle);
    puts("C packet ABI: callbacks, verified fixed stock lengths, split input, retained retry, opaque loader routing, ordered drain and truncated EOF passed.");
    return 0;
}
