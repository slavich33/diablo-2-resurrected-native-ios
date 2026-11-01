#include "dm_net_state_packets.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

int main(void) {
    unsigned char input[] = {0x96,0x78,0x56,0x34,0x12,0xff,0xff,0,0,0x80,0x81};
    const unsigned char original[] = {0x96,0x78,0x56,0x34,0x12,0xff,0xff,0,0,0x80,0x81};
    dm_net_small_state decoded;
    assert(dm_net_decode_small_state(input, sizeof(input), &decoded));
    assert(decoded.resource == 0x12345678 && decoded.x == 65535 && decoded.y == 0);
    assert(decoded.destination_x == 127 && decoded.destination_y == 65409);
    assert(!memcmp(input, original, sizeof(input)));
    for (unsigned n = 0; n < sizeof(input); n++) {
        dm_net_small_state untouched = {.resource=42};
        assert(!dm_net_decode_small_state(input, n, &untouched) && untouched.resource == 42);
    }
    assert(!dm_net_decode_small_state(input, sizeof(input)+1, &decoded));
    input[0] = 0x95;
    assert(!dm_net_decode_small_state(input, sizeof(input), &decoded));
    puts("Extended small state: exact boundary, full resource, delta edge and wraparound passed.");
}
