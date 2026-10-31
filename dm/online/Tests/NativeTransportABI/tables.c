// Own synthetic loaded-table fixture; no game assets or executable required.
#include "dm.h"
#include "dm_net_tables.h"
#include <assert.h>
module_t g_mod[MAX_MOD];
int g_nmod = 1;
static void (*loaded)(const uint64_t *);
int gate_obs_present(int id) { return id == OBS_NET_ITEMSTATCOST; }
void gate_obs_set(int id, void (*fn)(const uint64_t *)) { assert(id == OBS_NET_ITEMSTATCOST); loaded = fn; }

void dm_test_tables_load(int mode) {
    static uint64_t manager[0x2000 / 8], linker[8], heads[2], nodes[2][7];
    static unsigned char rows[648];
    if (!g_mod[0].base) {
        strcpy(g_mod[0].name, "main"); g_mod[0].size = 0x2d65000;
        g_mod[0].base = calloc(1, g_mod[0].size); assert(g_mod[0].base);
        memcpy(g_mod[0].base + 0x2d64a18 + 3 * 16, &(uint64_t){(uintptr_t)manager}, 8);
        dm_net_tables_install(); assert(loaded);
    }
    memset(rows, 0, sizeof rows); memset(linker, 0, sizeof linker); memset(nodes, 0, sizeof nodes);
    rows[0x15] = mode == 0 ? 10 : 11; rows[324 + 0xa] = 13; rows[324 + 0xb] = 3;
    linker[3] = 2; linker[4] = (uintptr_t)heads; linker[5] = mode == 3 ? 1 : 2;
    heads[0] = (uintptr_t)nodes[0]; heads[1] = 0;
    nodes[0][0] = mode == 3 ? 0 : (uintptr_t)nodes[1]; nodes[0][1] = (uintptr_t)"strength";
    nodes[0][2] = 8; nodes[0][3] = (UINT64_C(1) << 63) | 15; nodes[0][6] = 0;
    nodes[1][0] = mode == 2 ? (uintptr_t)nodes[0] : 0;
    nodes[1][1] = (uintptr_t)(mode == 1 ? "invalid\xff" : "own_synthetic_stat");
    nodes[1][2] = mode == 1 ? 8 : 18; nodes[1][3] = 18; nodes[1][6] = 1;
    manager[0x1290 / 8] = mode == 4 ? 4096 : (uintptr_t)rows;
    manager[0x1298 / 8] = 2; manager[0x12a0 / 8] = 2; manager[0x12a8 / 8] = (uintptr_t)linker;
    uint64_t regs[100] = {0}; regs[23] = (uintptr_t)manager; loaded(regs);
}
