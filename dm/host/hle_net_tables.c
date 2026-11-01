// Exact-build ItemStatCost capture. This is a read-only observation of the
// completed ARM64 loader, not a Windows layout cast or a polling memory read.
#include "dm.h"
#include "dm_net_tables.h"
#include <mach/mach.h>
#include <pthread.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <limits.h>
#include <stdatomic.h>

typedef struct {
    unsigned char *rows;
    char **names;
    dm_net_itemstatcost_info info;
    int status;
} table_snapshot;
static table_snapshot snapshots[3];
static pthread_mutex_t snapshots_lock = PTHREAD_MUTEX_INITIALIZER;
static _Thread_local int snapshot_pinned;

int dm_net_itemstatcost_pin(unsigned edition, uint64_t generation) {
    if (edition < 1 || edition > 3 || !generation || snapshot_pinned) return DM_NET_TABLE_INVALID;
    pthread_mutex_lock(&snapshots_lock);
    const table_snapshot *s = &snapshots[edition - 1];
    int status = generation == s->info.generation ? s->status : DM_NET_TABLE_STALE;
    if (status == DM_NET_TABLE_READY) snapshot_pinned = 1;
    else pthread_mutex_unlock(&snapshots_lock);
    return status;
}

int dm_net_itemstatcost_unpin(void) {
    if (!snapshot_pinned) return DM_NET_TABLE_INVALID;
    snapshot_pinned = 0;
    pthread_mutex_unlock(&snapshots_lock);
    return DM_NET_TABLE_READY;
}

static void free_names(table_snapshot *s) {
    if (s->names) for (uint32_t i = 0; i < s->info.row_count; ++i) free(s->names[i]);
    free(s->names); s->names = NULL; s->info.resolved_names = 0;
}

static int read_live(uint64_t address, void *out, size_t size) {
    vm_size_t got = 0;
    return address >= 4096 && size && address <= UINT64_MAX - size &&
        vm_read_overwrite(mach_task_self(), address, size, (vm_address_t)out, &got) == KERN_SUCCESS && got == size;
}

// The native linker folds ASCII case. Preserve the spelling from this load's
// actual text input, then accept it only when every ID matches the completed
// native linker. No resource path, external name list or host hash is used.
typedef struct {
    uint64_t manager, epoch;
    char **names;
    uint32_t count;
    int active, seen, invalid;
} table_source;
static _Thread_local table_source pending_source;
static _Atomic uint64_t source_epoch;

static void clear_source(table_source *s) {
    if (s->names) for (uint32_t i = 0; i < s->count; ++i) free(s->names[i]);
    free(s->names); memset(s, 0, sizeof *s);
}

static module_t *table_main(void) {
    for (int i = 0; i < g_nmod; ++i) if (!strcmp(g_mod[i].name, "main")) return &g_mod[i];
    return NULL;
}

static void itemstatcost_begin(const uint64_t *regs) {
    clear_source(&pending_source);
    pending_source.epoch = atomic_fetch_add(&source_epoch, 1) + 1;
    module_t *main = table_main();
    if (!main || main->size < 0x2d64a60 || regs[0] < 1 || regs[0] > 3) return;
    uint64_t manager = 0;
    if (!read_live((uintptr_t)main->base + 0x2d64a18 + regs[0] * 16, &manager, 8) || !manager) return;
    pending_source.active = 1; pending_source.manager = manager;
}

static int text_cell(const char *begin, const char *end, unsigned column,
                     const char **value, size_t *size) {
    const char *p = begin;
    for (unsigned i = 0; i < column; ++i) {
        const char *tab = memchr(p, '\t', (size_t)(end - p));
        if (!tab) return 0;
        p = tab + 1;
    }
    const char *tab = memchr(p, '\t', (size_t)(end - p));
    *value = p; *size = (size_t)((tab ? tab : end) - p);
    return 1;
}

static int source_names(table_source *s, const char *bytes, size_t size) {
    if (!size || memchr(bytes, 0, size)) return 0;
    const char *end = bytes + size, *line = memchr(bytes, '\n', size);
    if (!line) return 0;
    const char *header_end = line > bytes && line[-1] == '\r' ? line - 1 : line;
    const char *cell; size_t count;
    if (!text_cell(bytes, header_end, 0, &cell, &count) || count != 4 || memcmp(cell, "Stat", 4)) return 0;
    unsigned id_column = UINT_MAX;
    for (unsigned i = 1; i < 350 && text_cell(bytes, header_end, i, &cell, &count); ++i) {
        if ((count == 3 && !memcmp(cell, "*ID", 3)) || (count == 2 && !memcmp(cell, "ID", 2))) {
            if (id_column != UINT_MAX) return 0;
            id_column = i;
        }
    }
    if (id_column == UINT_MAX) return 0;
    s->names = calloc(DM_NET_ITEMSTATCOST_MAX_ROWS, sizeof *s->names);
    if (!s->names) return 0;
    for (const char *p = line + 1; p < end; p = line ? line + 1 : end) {
        line = memchr(p, '\n', (size_t)(end - p));
        const char *row_end = line ? line : end;
        if (row_end > p && row_end[-1] == '\r') --row_end;
        if (row_end == p || memchr(p, '\r', (size_t)(row_end - p)) || s->count >= DM_NET_ITEMSTATCOST_MAX_ROWS) return 0;
        if (!text_cell(p, row_end, id_column, &cell, &count) || !count || count > 5) return 0;
        unsigned id = 0;
        for (size_t i = 0; i < count; ++i) {
            if (cell[i] < '0' || cell[i] > '9') return 0;
            id = id * 10 + (unsigned)(cell[i] - '0');
        }
        if (id != s->count) return 0;
        if (!text_cell(p, row_end, 0, &cell, &count) || !count || count > 1024) return 0;
        char *name = malloc(count + 1);
        if (!name) return 0;
        memcpy(name, cell, count); name[count] = 0;
        s->names[s->count++] = name;
    }
    return s->count != 0;
}

static void itemstatcost_source(const uint64_t *regs) {
    module_t *main = table_main();
    if (!main || !pending_source.active || regs[23] != (uintptr_t)main->base + 0x4f8898) return;
    if (pending_source.seen++) { pending_source.invalid = 1; return; }
    uint64_t manager = 0, vector[3] = {0};
    // Generic-loader prologue saved its caller's x23 at [x29-0x28].
    // At this checked site x0+0x320 is the raw input vector, before parsing.
    if (regs[29] < 0x28 || regs[0] > UINT64_MAX - 0x320 ||
        !read_live(regs[29] - 0x28, &manager, 8) || manager != pending_source.manager ||
        !read_live(regs[0] + 0x320, vector, sizeof vector) ||
        !vector[1] || vector[1] > 8 * 1024 * 1024 || (vector[2] & INT64_MAX) < vector[1]) {
        pending_source.invalid = 1; return;
    }
    char *bytes = malloc((size_t)vector[1]);
    if (!bytes || !read_live(vector[0], bytes, (size_t)vector[1]) ||
        !source_names(&pending_source, bytes, (size_t)vector[1])) pending_source.invalid = 1;
    free(bytes);
}

static unsigned char ascii_lower(unsigned char c) { return c >= 'A' && c <= 'Z' ? c + ('a' - 'A') : c; }

static void retain_source_spelling(table_snapshot *s, table_source *source, uint64_t manager) {
    if (!source->active || !source->seen) return; // Binary/old observation builds keep their actual linker names.
    if (source->invalid || source->epoch != atomic_load(&source_epoch) || source->manager != manager || source->count != s->info.row_count ||
        !s->names || s->info.resolved_names != s->info.row_count) goto invalid;
    for (uint32_t i = 0; i < s->info.row_count; ++i) {
        if (!s->names[i] || !source->names[i]) goto invalid;
        const unsigned char *a = (unsigned char *)s->names[i], *b = (unsigned char *)source->names[i];
        for (; *a || *b; ++a, ++b) if (ascii_lower(*a) != ascii_lower(*b)) goto invalid;
    }
    free_names(s); s->names = source->names; s->info.resolved_names = source->count;
    source->names = NULL; source->count = 0;
    return;
invalid:
    free_names(s); // Never publish a partial/mismatched spelling set as a complete schema.
}

int dm_net_itemstatcost_copy(unsigned edition, uint64_t generation,
                            void *rows, size_t capacity,
                            dm_net_itemstatcost_info *info) {
    if (edition < 1 || edition > 3 || !info || (!rows && capacity) || snapshot_pinned) return DM_NET_TABLE_INVALID;
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
    if (edition < 1 || edition > 3 || !generation || !required || (!out && capacity) || snapshot_pinned) return DM_NET_TABLE_INVALID;
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
    table_source source = pending_source;
    memset(&pending_source, 0, sizeof pending_source);
    module_t *main = table_main();
    if (!main || main->size < 0x2d64a60) { clear_source(&source); return; }
    // x23 still holds the selected table manager at main+0x4f9600. Match
    // against the engine's edition slots; w20 has been reused by this point.
    unsigned edition = 0;
    for (unsigned e = 1; e <= 3; ++e) {
        uint64_t manager = 0;
        if (read_live((uintptr_t)main->base + 0x2d64a18 + e * 16, &manager, sizeof manager) && manager && manager == regs[23]) {
            if (edition) { clear_source(&source); return; } // Ambiguous manager: do not label data as an edition.
            edition = e;
        }
    }
    if (!edition) { clear_source(&source); return; }
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
    if (next.status == DM_NET_TABLE_READY) {
        capture_names(&next, regs[23]);
        retain_source_spelling(&next, &source, regs[23]);
    }
    clear_source(&source);
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
    if (gate_obs_present(OBS_NET_ITEMSTATCOST) && gate_obs_present(OBS_NET_ITEMSTATCOST_BEGIN) &&
        gate_obs_present(OBS_NET_ITEMSTATCOST_SOURCE)) {
        gate_obs_set(OBS_NET_ITEMSTATCOST_BEGIN, itemstatcost_begin);
        gate_obs_set(OBS_NET_ITEMSTATCOST_SOURCE, itemstatcost_source);
    }
}
