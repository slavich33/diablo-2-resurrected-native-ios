// Real host HLE filesystem + capture on owned synthetic data. No game image,
// account, server, OS API emulation or original engine entry point is used.
#include "driver.h"
#include <sys/clonefile.h>
#include <stdio.h>
static int failure;
static int fixture_clone(const char *, const char *, int);
static int fixture_swap(const char *, const char *, unsigned int);
#define clonefile fixture_clone
#define renamex_np fixture_swap
#include "../../../host/hle_fs.c"
#undef clonefile
#undef renamex_np
#include "../../../host/hle_net_tables.c"
#include <assert.h>
static int fixture_clone(const char *from, const char *to, int flags) {
    if (failure == 1) { failure = 0; errno = ENOSPC; return -1; }
    return clonefile(from, to, flags);
}
static int fixture_swap(const char *from, const char *to, unsigned int flags) {
    if (failure == 2) { failure = 0; errno = EIO; return -1; }
    int result = renamex_np(from, to, flags);
    if (!result && failure == 3) {
        failure = 0;
        char path[1600]; snprintf(path, sizeof path, "%s/NativeFixture/NativeFixture.d2s", to);
        FILE *file = fopen(path, "r+b"); assert(file);
        assert(!fseek(file, 450, SEEK_SET)); int byte = fgetc(file); assert(byte != EOF);
        assert(!fseek(file, 450, SEEK_SET)); assert(fputc(byte ^ 1, file) != EOF); assert(!fclose(file));
    }
    return result;
}
struct dm_flags g_flag; uint64_t g_t0_ns;
module_t g_mod[MAX_MOD]; int g_nmod;
uint64_t now_ns(void) { return 0; }
void dm_prof_add(int id, uint64_t ns, uint64_t count) { (void)id; (void)ns; (void)count; }
void dm_guest_write_prepare(void *p, size_t n) { (void)p; (void)n; }
static void (*table_observer)(const uint64_t *);
int gate_obs_present(int id) { return id == OBS_NET_ITEMSTATCOST; }
void gate_obs_set(int id, void (*fn)(const uint64_t *)) { assert(id == OBS_NET_ITEMSTATCOST); table_observer = fn; }
static uint64_t writer;
static int legacy_calls;
static void legacy_probe(const char *path) { (void)path; ++legacy_calls; }
void fixture_install_legacy_probes(void) {
    for (int i = 0; i < 5; ++i) g_dm_pre_commit_hook[i] = legacy_probe;
    g_dm_save_commit_hook = legacy_probe; g_dm_mount_seed_hook = legacy_probe;
}
int fixture_legacy_calls(void) { return legacy_calls; }
int fixture_mount(const char *directory) {
    dm_online_save_host_started();
    setenv("DM_SAVE", directory, 1); setenv("DM_TOUCH_DEFAULTS", "1", 1);
    return (int)h_fs_MountSave("save", NULL);
}
void fixture_cloud_boot(const char *directory) {
    extern void dm_cloud_boot(void);
    setenv("DM_TEST_ICLOUD_DIR", directory, 1); dm_cloud_boot(); unsetenv("DM_TEST_ICLOUD_DIR");
}
int fixture_write(const char *path, const void *bytes, size_t count, int keep_open) {
    assert(!writer);
    Result result = h_fs_OpenFile(&writer, path, MODE_WRITE);
    if (result) return (int)result;
    result = h_fs_SetFileSize(writer, (int64_t)count);
    if (!result) result = h_fs_WriteFile(writer, 0, bytes, count, NULL);
    if (!keep_open || result) fixture_close_writer();
    return (int)result;
}
void fixture_close_writer(void) { assert(writer); h_fs_CloseFile(writer); writer = 0; }
int fixture_commit(void) { return (int)h_fs_Commit("save"); }
void fixture_fail_next(int kind) { failure = kind; }
void fixture_capture_tables(void) {
    unsetenv("DM_NET_TABLE_CAPTURE_DIR");
    g_nmod = 1; strcpy(g_mod[0].name, "main"); g_mod[0].size = 0x2d65000;
    g_mod[0].base = calloc(1, g_mod[0].size); assert(g_mod[0].base);
    uint64_t *manager = calloc(1, 0x2000), linker[8] = {0}, heads[1] = {0}, node[7] = {0}, regs[100] = {0};
    unsigned char rows[324] = {0}; assert(manager);
    linker[3] = 1; linker[4] = (uintptr_t)heads; linker[5] = 1;
    node[1] = (uintptr_t)&node[4]; node[2] = 8; node[3] = (UINT64_C(1) << 63) | 15; memcpy(&node[4], "own_stat", 8);
    heads[0] = (uintptr_t)node; manager[0x12a8 / 8] = (uintptr_t)linker;
    manager[0x1290 / 8] = (uintptr_t)rows; manager[0x1298 / 8] = manager[0x12a0 / 8] = 1;
    memcpy(g_mod[0].base + 0x2d64a18 + 16 * 3, &(uint64_t){(uintptr_t)manager}, 8); regs[23] = (uintptr_t)manager;
    dm_net_tables_install(); assert(table_observer); table_observer(regs);
    free(manager); free(g_mod[0].base); g_mod[0].base = NULL; g_nmod = 0;
}
