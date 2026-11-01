#ifndef DM_ITEM_FORMAT_H
#define DM_ITEM_FORMAT_H
#include <stdint.h>

/* Supported engine bit-reader ABI. The caller owns the bounded input buffer. */
typedef struct {
    const unsigned char *cursor;
    uint64_t bit_count, consumed_bytes, bit_offset;
    uint32_t error, reserved;
} dm_item_bits;

typedef struct { unsigned extended, failed; } dm_item_format;

uint32_t dm_item_bits_read(dm_item_bits *bits, unsigned count);
uint32_t dm_item_format_finish_flags(dm_item_format *format, dm_item_bits *bits, uint32_t flags);
uint32_t dm_item_format_read_flags(dm_item_format *format, dm_item_bits *bits);
uint32_t dm_item_format_read_identity(dm_item_format *format, dm_item_bits *bits, unsigned retail_width);
uint32_t dm_item_format_read_magic_affix(dm_item_format *format, dm_item_bits *bits,
                                         unsigned retail_width, int runeword);
uint32_t dm_item_format_read_rare_name(dm_item_format *format, dm_item_bits *bits, unsigned retail_width);
#endif
