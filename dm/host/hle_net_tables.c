// Exact-build ItemStatCost capture. This is a read-only observation of the
// completed ARM64 loader, not a Windows layout cast or a polling memory read.
#include "dm.h"
#include "dm_net_tables.h"
#include <mach/mach.h>
#include <pthread.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

typedef struct {
    unsigned char *rows;
    char **names;
    dm_net_itemstatcost_info info;
    int status;
} table_snapshot;
static table_snapshot snapshots[3];
static pthread_mutex_t snapshots_lock = PTHREAD_MUTEX_INITIALIZER;

static void free_names(table_snapshot *s) {
    if (s->names) for (uint32_t i = 0; i < s->info.row_count; ++i) free(s->names[i]);
    free(s->names); s->names = NULL; s->info.resolved_names = 0;
}

static int read_live(uint64_t address, void *out, size_t size) {
    vm_size_t got = 0;
    return address >= 4096 && size && address <= UINT64_MAX - size &&
        vm_read_overwrite(mach_task_self(), address, size, (vm_address_t)out, &got) == KERN_SUCCESS && got == size;
}

int dm_net_itemstatcost_copy(unsigned edition, uint64_t generation,
                            void *rows, size_t capacity,
                            dm_net_itemstatcost_info *info) {
    if (edition < 1 || edition > 3 || !info || (!rows && capacity)) return DM_NET_TABLE_INVALID;
    pthread_mutex_lock(&snapshots_lock);
    const table_snapshot *s = &snapshots[edition - 1];
    int status = s->status;
    *info = s->info;
    if (generation && generation != s->info.generation) status = DM_NET_TABLE_STALE;
    else if (status == DM_NET_TABLE_READY && rows) {
        size_t bytes = (size_t)s->info.row_count * DM_NET_ITEMSTATCOST_ROW_BYTES;
        if (!generation) status = DM_NET_TABLE_INVALID;
        else if (capacity < bytes) status = DM_NET_TABLE_CAPACITY;
        else memcpy(rows, s->rows, bytes);
    }
    pthread_mutex_unlock(&snapshots_lock);
    return status;
}

int dm_net_itemstatcost_name(unsigned edition, uint64_t generation, unsigned stat_id,
                            char *out, size_t capacity, size_t *required) {
    if (edition < 1 || edition > 3 || !generation || !required || (!out && capacity)) return DM_NET_TABLE_INVALID;
    *required = 0;
    pthread_mutex_lock(&snapshots_lock);
    const table_snapshot *s = &snapshots[edition - 1];
    int status = s->status;
    if (generation != s->info.generation) status = DM_NET_TABLE_STALE;
    else if (status == DM_NET_TABLE_READY) {
        if (!s->names) status = DM_NET_TABLE_CAPTURE_FAILED;
        else if (stat_id >= s->info.row_count || !s->names[stat_id]) status = DM_NET_TABLE_UNAVAILABLE;
        else {
            *required = strlen(s->names[stat_id]) + 1;
            if (out && capacity < *required) status = DM_NET_TABLE_CAPACITY;
            else if (out) memcpy(out, s->names[stat_id], *required);
        }
    }
    pthread_mutex_unlock(&snapshots_lock);
    return status;
}

// Native Linker layout is independently grounded in its original lookup
// (de4880..de4b6c) and destructor: buckets +18/+20, size +28; node next +0,
// string pointer/length/capacity +8/+10/+18, numeric value +30. String data
// is copied through its pointer even for the inline representation.
static int capture_names(table_snapshot *s, uint64_t manager) {
    uint64_t pointer = 0, header[8];
    if (!read_live(manager + 0x12a8, &pointer, 8) || !read_live(pointer, header, sizeof header)) return 0;
    const uint64_t buckets = header[3], entries = header[5];
    if (!buckets || buckets > 65536 || (buckets & (buckets - 1)) || !entries || entries > s->info.row_count) return 0;
    uint64_t *heads = malloc((size_t)buckets * 8);
    s->names = calloc(s->info.row_count, sizeof *s->names);
    if (!heads || !s->names || !read_live(header[4], heads, (size_t)buckets * 8)) { free(heads); free_names(s); return 0; }
    uint32_t count = 0;
    for (uint64_t b = 0; b < buckets; ++b) {
        uint64_t node = heads[b];
        while (node) {
            uint64_t n[7];
            if (count >= entries || !read_live(node, n, sizeof n)) goto invalid;
            uint32_t id = (uint32_t)n[6];
            if (id >= s->info.row_count || s->names[id] || !n[2] || n[2] > 1024 || (n[3] & INT64_MAX) < n[2]) goto invalid;
            char *name = malloc((size_t)n[2] + 1);
            if (!name) goto invalid;
            if (!read_live(n[1], name, (size_t)n[2]) || memchr(name, 0, (size_t)n[2])) { free(name); goto invalid; }
            name[n[2]] = 0; s->names[id] = name;
            ++count; node = n[0];
        }
    }
    free(heads);
    if (count != entries) { free_names(s); return 0; }
    s->info.resolved_names = count;
    return 1;
invalid:
    free(heads); free_names(s); return 0;
}

// Explicit diagnostic export only. The caller creates a private directory;
// captured game rows are never source files, public fixtures or network data.
static void diagnostic_export(const table_snapshot *s) {
    const char *path = getenv("DM_NET_TABLE_CAPTURE_DIR");
    if (!path || !*path || s->status != DM_NET_TABLE_READY) return;
    int dir = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    if (dir < 0) return;
    char name[96];
    snprintf(name, sizeof name, "itemstatcost-%u-%llu.private.bin", s->info.edition,
             (unsigned long long)s->info.generation);
    int file = openat(dir, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    close(dir);
    if (file < 0) return;
    size_t size = (size_t)s->info.row_count * DM_NET_ITEMSTATCOST_ROW_BYTES, written = 0;
    while (written < size) {
        ssize_t n = write(file, s->rows + written, size - written);
        if (n <= 0) break;
        written += (size_t)n;
    }
    close(file);
    if (written != size) LOG("net-tables: diagnostic export incomplete");
    if (s->names) {
        dir = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
        if (dir < 0) return;
        snprintf(name, sizeof name, "itemstatcost-names-%u-%llu.private.bin", s->info.edition,
                 (unsigned long long)s->info.generation);
        file = openat(dir, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
        close(dir);
        if (file < 0) return;
        FILE *stream = fdopen(file, "wb");
        if (!stream) { close(file); return; }
        for (uint32_t id = 0; id < s->info.row_count; ++id) if (s->names[id]) {
            uint32_t fields[2] = {id, (uint32_t)strlen(s->names[id])};
            if (fwrite(fields, sizeof fields, 1, stream) != 1 || fwrite(s->names[id], fields[1], 1, stream) != 1) break;
        }
        fclose(stream);
    }
}

static void itemstatcost_loaded(const uint64_t *regs) {
    module_t *main = NULL;
    for (int i = 0; i < g_nmod; ++i) if (!strcmp(g_mod[i].name, "main")) main = &g_mod[i];
    if (!main || main->size < 0x2d64a60) return;
    // x23 still holds the selected table manager at main+0x4f9600. Match
    // against the engine's edition slots; w20 has been reused by this point.
    unsigned edition = 0;
    for (unsigned e = 1; e <= 3; ++e) {
        uint64_t manager = 0;
        if (read_live((uintptr_t)main->base + 0x2d64a18 + e * 16, &manager, sizeof manager) && manager && manager == regs[23]) {
            if (edition) return; // Ambiguous manager: do not label data as an edition.
            edition = e;
        }
    }
    if (!edition) return;
    uint64_t header[3] = {0};
    table_snapshot next = {.status = DM_NET_TABLE_CAPTURE_FAILED};
    next.info.edition = edition; next.info.row_bytes = DM_NET_ITEMSTATCOST_ROW_BYTES;
    if (regs[23] <= UINT64_MAX - 0x12a8 && read_live(regs[23] + 0x1290, header, sizeof header)) {
        const uint64_t count = header[1], capacity = header[2] & INT64_MAX;
        if (count && count <= DM_NET_ITEMSTATCOST_MAX_ROWS && count <= capacity) {
            size_t size = (size_t)count * DM_NET_ITEMSTATCOST_ROW_BYTES;
            next.rows = malloc(size);
            if (next.rows && read_live(header[0], next.rows, size)) {
                next.info.row_count = (uint32_t)count; next.status = DM_NET_TABLE_READY;
            } else { free(next.rows); next.rows = NULL; }
        }
    }
    if (next.status == DM_NET_TABLE_READY) capture_names(&next, regs[23]);
    pthread_mutex_lock(&snapshots_lock);
    table_snapshot *old = &snapshots[edition - 1];
    next.info.generation = old->info.generation + 1;
    if (!next.info.generation) next.info.generation = 1;
    free(old->rows); free_names(old); *old = next;
    // Export under the lock so a concurrent reload cannot release its bytes.
    diagnostic_export(old);
    pthread_mutex_unlock(&snapshots_lock);
    LOG("net-tables: edition=%u generation=%llu rows=%u names=%u status=%d", edition,
        (unsigned long long)next.info.generation, next.info.row_count, next.info.resolved_names, next.status);
}

void dm_net_tables_install(void) {
    if (gate_obs_present(OBS_NET_ITEMSTATCOST)) gate_obs_set(OBS_NET_ITEMSTATCOST, itemstatcost_loaded);
}
