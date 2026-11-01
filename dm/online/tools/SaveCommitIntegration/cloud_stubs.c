// Link-only tripwires for the REAL cloud_ios.m boot guard. The isolated test
// must return before consulting settings or any sync operation. No real cloud.
#include <stdint.h>
static int calls;
int fixture_cloud_probe_calls(void) { return calls; }
int dm_custom_get(const char *key) { (void)key; ++calls; return 0; }
int dm_cloud_sync(const char *s, const char *c, const char *b, const char *f, int down, uint64_t now, int (*ready)(const char *)) {
    (void)s; (void)c; (void)b; (void)f; (void)down; (void)now; (void)ready; ++calls; return -1;
}
int dm_cloud_inbox_add(const char *s, const char *f, const char *p) { (void)s; (void)f; (void)p; ++calls; return -1; }
uint64_t dm_cloud_pack_stamp(const char *p) { (void)p; ++calls; return 0; }
int dm_cloud_bak_pack(const char *b, const char *u, const char *p, const char *w) { (void)b; (void)u; (void)p; (void)w; ++calls; return -1; }
void dm_cloud_char_conflict_note(const char *u) { (void)u; ++calls; }
void (*g_dm_ingame_hook)(int);
void (*g_dm_charsel_hook)(void);
