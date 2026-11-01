#pragma once
#include <stddef.h>
#include <stdint.h>

enum { DM_NET_TABLE_READY = 1, DM_NET_TABLE_UNAVAILABLE = 0,
       DM_NET_TABLE_INVALID = -1, DM_NET_TABLE_STALE = -2,
       DM_NET_TABLE_CAPACITY = -3, DM_NET_TABLE_CAPTURE_FAILED = -4 };
enum { DM_NET_ITEMSTATCOST_ROW_BYTES = 324, DM_NET_ITEMSTATCOST_MAX_ROWS = 32768 };

typedef struct {
    uint64_t generation;
    uint32_t edition, row_count, row_bytes, resolved_names;
} dm_net_itemstatcost_info;

// Install only if the exact-build, build-time observation gate is present.
// Capture runs synchronously at the table loader's normal epilogue, before
// the game can release/reuse its rows. No game pointer escapes this module.
void dm_net_tables_install(void);

// Query with rows=NULL/capacity=0/generation=0, then copy with that generation.
// A reload between query and copy returns STALE without writing any row bytes.
// Each successful copy is owned by the caller and remains valid after reload.
// Names are copied from the loaded edition's linker, never a bundled base-game
// name list. resolved_names=0 means linker capture failed; rows can still be read.
// Mod identity, active-environment verification and save admission are separate.
int dm_net_itemstatcost_copy(unsigned edition, uint64_t generation,
                            void *rows, size_t capacity,
                            dm_net_itemstatcost_info *info);

// Required size includes the terminating NUL. Query with out=NULL/capacity=0.
// Generation is mandatory even for a query; missing/invalid names fail closed.
int dm_net_itemstatcost_name(unsigned edition, uint64_t generation, unsigned stat_id,
                            char *out, size_t capacity, size_t *required);

// Pin the published captured snapshot across a short local save commit. Copy
// rows/names BEFORE pinning. READY holds the capture-publication mutex until
// unpin on the SAME thread; failed pin holds nothing. No nested pin or copy/name
// query on that thread while pinned. This does not suspend the engine or grant
// admission: its environment/lifecycle must independently remain bound.
int dm_net_itemstatcost_pin(unsigned edition, uint64_t generation);
int dm_net_itemstatcost_unpin(void);
