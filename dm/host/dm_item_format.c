/* Independent read-side implementation of the observed extended item format5.
 * This codec neither authorizes a peer nor changes the serialized input. */
#include "dm_item_format.h"
#include <stddef.h>
#include <limits.h>

_Static_assert(sizeof(void *) == 8, "Supported engine has 64-bit pointers");
_Static_assert(offsetof(dm_item_bits, bit_count) == 8, "bit-reader layout");
_Static_assert(offsetof(dm_item_bits, consumed_bytes) == 16, "bit-reader layout");
_Static_assert(offsetof(dm_item_bits, bit_offset) == 24, "bit-reader layout");
_Static_assert(offsetof(dm_item_bits, error) == 32 && sizeof(dm_item_bits) == 40, "bit-reader layout");

uint32_t dm_item_bits_read(dm_item_bits *bits, unsigned count) {
    if (!bits) return 0;
    if (count > 32 || bits->bit_offset > 7 || bits->consumed_bytes > bits->bit_count / 8) {
        bits->error = 1; return 0;
    }
    uint64_t used = bits->consumed_bytes * 8;
    if (bits->bit_offset > bits->bit_count - used) { bits->error = 1; return 0; }
    uint64_t available = bits->bit_count - used - bits->bit_offset;
    unsigned remaining = available < count ? (unsigned)available : count;
    if (remaining < count) bits->error = 1;
    if (remaining && !bits->cursor) { bits->error = 1; return 0; }
    uint32_t result = 0;
    unsigned written = 0;
    while (remaining) {
        unsigned take = 8 - (unsigned)bits->bit_offset;
        if (take > remaining) take = remaining;
        uint32_t part = ((uint32_t)*bits->cursor >> bits->bit_offset) & ((1u << take) - 1u);
        result |= part << written;
        written += take; remaining -= take; bits->bit_offset += take;
        if (bits->bit_offset == 8) {
            bits->cursor++; bits->consumed_bytes++; bits->bit_offset = 0;
        }
    }
    return result;
}

uint32_t dm_item_format_finish_flags(dm_item_format *format, dm_item_bits *bits, uint32_t flags) {
    if (!format || !bits) return 0;
    format->extended = !!(flags & 0x80000u);
    if (format->extended) {
        uint32_t version = dm_item_bits_read(bits, 8);
        if (version != 5 || bits->error) format->failed = 1;
    }
    return flags & ~0x80000u;
}

uint32_t dm_item_format_read_flags(dm_item_format *format, dm_item_bits *bits) {
    return dm_item_format_finish_flags(format, bits, dm_item_bits_read(bits, 32));
}

uint32_t dm_item_format_read_identity(dm_item_format *format, dm_item_bits *bits, unsigned retail_width) {
    uint32_t value = dm_item_bits_read(bits, format->extended ? 16 : retail_width);
    uint32_t sentinel = format->extended ? 0xffffu : 0xfffu;
    if (format->extended && (bits->error || (value >= 0x8000u && value != 0xffffu))) format->failed = 1;
    return value == sentinel ? UINT32_MAX : value;
}

uint32_t dm_item_format_read_magic_affix(dm_item_format *format, dm_item_bits *bits,
                                         unsigned retail_width, int runeword) {
    uint32_t value = dm_item_bits_read(bits, format->extended ? 16 : retail_width);
    if (value <= 0x8000u && !bits->error) return value;
    if (format->extended && !bits->error && runeword) return 0;
    bits->error = 1; format->failed = 1; return 0;
}

uint32_t dm_item_format_read_rare_name(dm_item_format *format, dm_item_bits *bits, unsigned retail_width) {
    uint32_t value = dm_item_bits_read(bits, format->extended ? 17 : retail_width);
    if (value <= 0x10000u && !bits->error) return value;
    bits->error = 1; format->failed = 1; return 0;
}
