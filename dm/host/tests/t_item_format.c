#include "dm_item_format.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static dm_item_bits reader(const unsigned char *input, uint64_t count) {
    return (dm_item_bits){.cursor=input,.bit_count=count*8};
}
int main(void) {
    const unsigned char header[] = {0x10,0,0x28,0,5,0xab};
    dm_item_bits bits=reader(header,sizeof(header));dm_item_format format={0};
    assert(dm_item_format_read_flags(&format,&bits)==0x200010u);
    assert(format.extended && !format.failed && !bits.error);
    assert(bits.consumed_bytes==5 && bits.bit_offset==0);
    assert(dm_item_bits_read(&bits,8)==0xab);
    assert(!memcmp(header,(const unsigned char[]){0x10,0,0x28,0,5,0xab},sizeof(header)));

    const unsigned char retail[]={0x10,0,0x20,0,0xab};
    bits=reader(retail,sizeof(retail));format=(dm_item_format){0};
    assert(dm_item_format_read_flags(&format,&bits)==0x200010u);
    assert(!format.extended && !format.failed && bits.consumed_bytes==4);
    assert(dm_item_bits_read(&bits,8)==0xab);

    for (unsigned n=0;n<5;n++) {
        bits=reader(header,n);format=(dm_item_format){0};
        (void)dm_item_format_read_flags(&format,&bits);
        assert(bits.error && bits.consumed_bytes==n);
    }
    unsigned char changed[sizeof(header)];memcpy(changed,header,sizeof(header));changed[4]=6;
    bits=reader(changed,sizeof(changed));format=(dm_item_format){0};
    assert(dm_item_format_read_flags(&format,&bits)==0x200010u && format.failed && !bits.error);

    const unsigned char words[]={0xff,0xff,0x00,0x80};
    bits=reader(words,sizeof(words));format=(dm_item_format){.extended=1};
    assert(dm_item_format_read_identity(&format,&bits,12)==UINT32_MAX && !format.failed);
    assert(dm_item_format_read_identity(&format,&bits,12)==0x8000 && format.failed);
    bits=reader(words,sizeof(words));format=(dm_item_format){.extended=1};
    assert(dm_item_format_read_magic_affix(&format,&bits,11,1)==0 && !format.failed && !bits.error);
    assert(dm_item_format_read_magic_affix(&format,&bits,11,0)==0x8000 && !format.failed);
    bits=reader(words,sizeof(words));format=(dm_item_format){.extended=1};
    assert(dm_item_format_read_magic_affix(&format,&bits,11,0)==0 && format.failed && bits.error);

    const unsigned char rare[]={0x00,0x00,0x01};
    bits=reader(rare,sizeof(rare));format=(dm_item_format){.extended=1};
    assert(dm_item_format_read_rare_name(&format,&bits,8)==0x10000 && !format.failed);
    bits=(dm_item_bits){.bit_count=1,.bit_offset=8};
    assert(dm_item_bits_read(&bits,32)==0 && bits.error);
    bits=(dm_item_bits){.bit_count=UINT64_MAX,.consumed_bytes=UINT64_MAX};
    assert(dm_item_bits_read(&bits,1)==0 && bits.error);
    puts("Item-format reader: bounded prefix, legacy cursor, wide IDs, sentinels and failures passed.");
}
