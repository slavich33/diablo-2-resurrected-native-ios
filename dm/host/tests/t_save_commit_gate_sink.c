#include "../dm_save_completion.h"
#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int gate_refusal, gate_poison, gate_prepares, gate_finishes, gate_committed, legacy_count;
extern void dm_fs_save_poison(int);
static int entered;
static char prepared[32];

int dm_online_save_prepare(const char *workdir, const char *commitdir) {
    (void)commitdir;
    assert(!entered && legacy_count == 5); entered = 1; ++gate_prepares;
    if (gate_refusal) return gate_refusal;
    if (gate_poison) { dm_fs_save_poison(EIO); return 0; }
    char path[1300], tmp[1400];
    snprintf(path, sizeof path, "%s/Target.d2s", workdir);
    FILE *file = fopen(path, "rb"); assert(file);
    memset(prepared, 0, sizeof prepared); assert(fread(prepared, 1, sizeof prepared - 1, file)); fclose(file);
    snprintf(path, sizeof path, "%s/Target.d2rl", workdir);
    snprintf(tmp, sizeof tmp, "%s.tmp", path);
    file = fopen(tmp, "wb"); assert(file);
    assert(fwrite(prepared, strlen(prepared), 1, file) == 1 && !fclose(file));
    assert(!rename(tmp, path));
    return 0;
}

void dm_online_save_finished(const char *workdir, const char *commitdir, int committed) {
    (void)workdir;
    assert(entered); entered = 0; ++gate_finishes; gate_committed = committed;
    if (committed) {
        char path[1300], data[32] = {0};
        snprintf(path, sizeof path, "%s/Target.d2rl", commitdir);
        FILE *file = fopen(path, "rb"); assert(file);
        assert(fread(data, 1, sizeof data - 1, file)); fclose(file);
        assert(!strcmp(data, prepared));
    }
}
