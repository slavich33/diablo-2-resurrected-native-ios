/* Exact-build item-reader service. Only activated remote decoder generations in
 * an isolated server-save namespace opt in. Borrowed packets retain their format after transport failure. Unbound state is untouched. */
#include "dm_item_format.h"
#include "dm_net_binding.h"
#include "dm_save_completion.h"

void svc_item_format_flags(uint64_t *regs) {
    if (!regs || !dm_net_remote_decode_generation() || dm_online_save_isolated() != 1) return;
    dm_item_bits *bits = (dm_item_bits *)(uintptr_t)regs[1];
    if (!bits) return;
    dm_item_format format = {0};
    regs[0] = dm_item_format_finish_flags(&format, bits, (uint32_t)regs[0]);
    if (format.failed) bits->error = 1;
}
