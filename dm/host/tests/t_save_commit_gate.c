// Actual filesystem transaction; synthetic bytes, not game data or signatures.
#include <stdio.h>
#include <stdlib.h>
#include <sys/clonefile.h>
static int fail_clone, fail_swap;
static int gate_clonefile(const char *, const char *, int);
static int gate_renamex(const char *, const char *, unsigned int);
#define clonefile gate_clonefile
#define renamex_np gate_renamex
#include "../hle_fs.c"
#undef clonefile
#undef renamex_np
#include <assert.h>
static int gate_clonefile(const char *from, const char *to, int flags) {
    if (fail_clone) { fail_clone = 0; errno = ENOSPC; return -1; }
    return clonefile(from, to, flags);
}
static int gate_renamex(const char *from, const char *to, unsigned int flags) {
    if (fail_swap) { fail_swap = 0; errno = EIO; return -1; }
    return renamex_np(from, to, flags);
}
struct dm_flags g_flag; uint64_t g_t0_ns;
uint64_t now_ns(void) { return 0; }
void dm_prof_add(int id, uint64_t ns, uint64_t n) { (void)id; (void)ns; (void)n; }
void dm_guest_write_prepare(void *p, size_t n) { (void)p; (void)n; }
extern int gate_refusal, gate_poison, gate_prepares, gate_finishes, gate_committed, legacy_count;
static void put(const char *path, const char *text) { FILE *f = fopen(path, "wb"); assert(f); assert(fwrite(text, strlen(text), 1, f) == 1); assert(!fclose(f)); }
static int contains(const char *path, const char *text) { char bytes[32] = {0}; FILE *f = fopen(path, "rb"); assert(f); fread(bytes, 1, sizeof bytes - 1, f); fclose(f); return !strcmp(bytes, text); }
static void legacy0(const char *p) { (void)p; assert(legacy_count++ == 0); }
static void legacy1(const char *p) { (void)p; assert(legacy_count++ == 1); }
static void legacy2(const char *p) { (void)p; assert(legacy_count++ == 2); }
static void legacy3(const char *p) { (void)p; assert(legacy_count++ == 3); }
static void legacy4(const char *p) { (void)p; assert(legacy_count++ == 4); }
static Result commit(void) { legacy_count = 0; return h_fs_Commit("save"); }
int main(void) {
    char root[1024], save[1200], d2s[1300], sidecar[1300], work[1300];
    snprintf(root, sizeof root, "%s/t_save_commit_gate.XXXXXX", getenv("TMPDIR") ? getenv("TMPDIR") : "/private/tmp");
    assert(mkdtemp(root)); snprintf(save, sizeof save, "%s/save", root); assert(!mkdir(save, 0700));
    snprintf(d2s, sizeof d2s, "%s/Target.d2s", save); put(d2s, "old-save");
    snprintf(sidecar, sizeof sidecar, "%s/Target.d2rl", save); put(sidecar, "old-sidecar");
    setenv("DM_SAVE", save, 1); assert(!h_fs_MountSave("save", NULL));
    g_dm_pre_commit_hook[0] = legacy0; g_dm_pre_commit_hook[1] = legacy1; g_dm_pre_commit_hook[2] = legacy2;
    g_dm_pre_commit_hook[3] = legacy3; g_dm_pre_commit_hook[4] = legacy4;
    snprintf(work, sizeof work, "%s/Target.d2s", dm_save_workdir()); put(work, "new-save");
    gate_refusal = EAGAIN;
    assert(commit() != RES_OK && gate_prepares == 1 && gate_finishes == 1 && !gate_committed);
    assert(contains(d2s, "old-save") && contains(sidecar, "old-sidecar") && contains(work, "new-save"));
    assert(!atomic_load(&g_save_poison)); // A deferred metadata match must not roll back a valid pending save.
    gate_refusal = 0; fail_clone = 1;
    assert(commit() != RES_OK && gate_prepares == 2 && gate_finishes == 2 && !gate_committed);
    assert(contains(d2s, "old-save") && contains(sidecar, "old-sidecar") && contains(work, "new-save"));
    fail_swap = 1;
    assert(commit() != RES_OK && gate_prepares == 3 && gate_finishes == 3 && !gate_committed);
    assert(contains(d2s, "old-save") && contains(sidecar, "old-sidecar") && contains(work, "new-save"));
    assert(!commit() && gate_prepares == 4 && gate_finishes == 4 && gate_committed);
    assert(contains(d2s, "new-save") && contains(sidecar, "new-save"));
    gate_poison = 1;
    assert(commit() != RES_OK && gate_prepares == 5 && gate_finishes == 5 && !gate_committed);
    gate_poison = 0;
    assert(contains(d2s, "new-save") && contains(sidecar, "new-save"));
    uint64_t h; assert(!h_fs_OpenFile(&h, "save:/Target.d2s", MODE_WRITE));
    assert(h_fs_SetFileSize(h, -1) != RES_OK); h_fs_CloseFile(h);
    assert(commit() != RES_OK && gate_prepares == 5 && gate_finishes == 5); // Damaged writer follows existing rollback, gate not entered.
    assert(contains(d2s, "new-save") && contains(sidecar, "new-save"));
    assert(!rm_tree(root));
    puts("Remote save commit gate: five legacy hooks, defer/retry, clone/swap failure, atomic pair, balanced lease, poisoned rollback passed");
}
