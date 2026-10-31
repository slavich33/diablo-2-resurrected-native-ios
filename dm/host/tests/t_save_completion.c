// Real host filesystem close/rename/commit; no game resources or account.
#include "../hle_fs.c"
#include <assert.h>
struct dm_flags g_flag; uint64_t g_t0_ns;
uint64_t now_ns(void) { return 0; }
void dm_prof_add(int id, uint64_t ns, uint64_t bytes) { (void)id; (void)ns; (void)bytes; }
void dm_guest_write_prepare(void *address, size_t size) { (void)address; (void)size; }
extern int sink_count, sink_reason, sink_expected_closed_fd;
extern uint64_t sink_sequence;
extern char sink_data[64], sink_path[1024];
static void put(const char *path, const char *text) { FILE *f = fopen(path, "wb"); assert(f); assert(fwrite(text, strlen(text), 1, f) == 1); fclose(f); }
static int contains(const char *path, const char *text) { char bytes[64] = {0}; FILE *f = fopen(path, "rb"); assert(f); fread(bytes, 1, sizeof bytes - 1, f); fclose(f); return !strcmp(bytes, text); }

int main(void) {
    char root[1024], save[1200], path[1300];
    snprintf(root, sizeof root, "%s/t_save_completion.XXXXXX", getenv("TMPDIR") ? getenv("TMPDIR") : "/private/tmp");
    assert(mkdtemp(root)); snprintf(save, sizeof save, "%s/save", root); assert(!mkdir(save, 0700));
    snprintf(path, sizeof path, "%s/Target.d2s", save); put(path, "seed");
    setenv("DM_SAVE", save, 1); assert(h_fs_MountSave("save", NULL) == RES_OK);
    uint64_t h;
    assert(!h_fs_OpenFile(&h, "save:/Target.d2s", MODE_WRITE));
    assert(!h_fs_SetFileSize(h, 4)); assert(!h_fs_WriteFile(h, 0, "done", 4, NULL));
    sink_expected_closed_fd = (int)h; h_fs_CloseFile(h);
    assert(sink_count == 1 && sink_reason == DM_SAVE_COMPLETION_CLOSE && !strcmp(sink_data, "done"));
    assert(sink_sequence == dm_fs_d2s_wseq());
    assert(!h_fs_Commit("save") && contains(path, "done"));
    assert(!h_fs_OpenFile(&h, "save:/Target.d2s", MODE_READ)); h_fs_CloseFile(h); assert(sink_count == 1);
    assert(!h_fs_CreateFile("save:/Rename.tmp", 4));
    assert(!h_fs_OpenFile(&h, "save:/Rename.tmp", MODE_WRITE));
    assert(!h_fs_WriteFile(h, 0, "move", 4, NULL)); h_fs_CloseFile(h); assert(sink_count == 1);
    assert(!h_fs_RenameFile("save:/Rename.tmp", "save:/Renamed.d2s"));
    assert(sink_count == 2 && sink_reason == DM_SAVE_COMPLETION_RENAME && !strcmp(sink_data, "move"));
    uint64_t sequence = dm_fs_d2s_wseq();
    assert(h_fs_RenameFile("save:/Target.d2s", "save:/Renamed.d2s") != RES_OK);
    assert(sink_count == 2 && dm_fs_d2s_wseq() == sequence);
    assert(!h_fs_OpenFile(&h, "save:/Target.d2s", MODE_WRITE));
    assert(!h_fs_WriteFile(h, 0, "fail", 4, NULL)); assert(!close((int)h));
    sink_expected_closed_fd = -1; h_fs_CloseFile(h);
    assert(sink_count == 2 && dm_fs_d2s_wseq() == sequence && atomic_load(&g_save_poison) == EBADF);
    assert(h_fs_Commit("save") != RES_OK && contains(path, "done"));
    assert(!h_fs_OpenFile(&h, "save:/Target.d2s", MODE_WRITE));
    assert(h_fs_SetFileSize(h, -1) != RES_OK); // Real failed writer operation poisons this transaction.
    sink_expected_closed_fd = (int)h; h_fs_CloseFile(h);
    assert(sink_count == 2 && atomic_load(&g_save_poison));
    assert(h_fs_Commit("save") != RES_OK && contains(path, "done"));
    sequence = dm_fs_d2s_wseq();
    d2s_note_sequence(sequence + 2); d2s_note_sequence(sequence + 1);
    assert(dm_fs_d2s_wseq() == sequence + 2); // Late producer cannot move the marker backward.
    assert(!rm_tree(root));
    puts("D2S completion: successful writer close/rename only, already-closed FD, readable final bytes, failed-close rollback passed");
}
