#pragma once
#include <stddef.h>
#include <stdint.h>
#include "../../../host/dm_net_tables.h"
int fixture_mount(const char *directory);
int fixture_write(const char *guest_path, const void *bytes, size_t count, int keep_open);
void fixture_close_writer(void);
int fixture_commit(void);
void fixture_fail_next(int kind);
void fixture_capture_tables(void);
void fixture_install_legacy_probes(void);
int fixture_legacy_calls(void);
int fixture_cloud_probe_calls(void);
void fixture_cloud_boot(const char *local_directory);
