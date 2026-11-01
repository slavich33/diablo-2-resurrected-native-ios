#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
enum { DM_SAVE_COMPLETION_CLOSE = 1, DM_SAVE_COMPLETION_RENAME = 2 };
// Optional linked native coordinator hook, called only after successful close
// of a writer D2S or successful rename to D2S. path is borrowed for this call;
// copy it before returning. Calls may occur on an engine IO thread.
// This is NOT a serialization number, committed save, server receipt or proof
// of admission. A receiver must bind an isolated authenticated server namespace
// and match complete bytes to received metadata before preparing a sidecar.
// Weak defaults in hle_fs.c are disabled/no-op. A linked receiver overrides
// both functions and returns nonzero only while its explicit scope is bound.
int dm_online_d2s_completion_enabled(void);
void dm_online_d2s_completed(const char *path, uint64_t sequence, int reason);
// Dedicated final gate AFTER the five legacy side-file hooks, before cloning
// and atomic directory swap. Zero allows commit; a positive errno defers it,
// retaining the current work tree and the previous committed tree. Never wait
// for network here or call back into game FS: path/mount locks are held.
// finished is called exactly once for every prepare, on this same thread,
// including a refused prepare or failed clone/swap. It is not a server receipt.
// A linked coordinator can hold its namespace/generation lease across the pair.
int dm_online_save_prepare(const char *workdir, const char *commitdir);
void dm_online_save_finished(const char *workdir, const char *commitdir, int committed);
#ifdef __cplusplus
}
#endif
