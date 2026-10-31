#include "../dm_save_completion.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>

int sink_count, sink_reason, sink_expected_closed_fd = -1;
uint64_t sink_sequence;
char sink_data[64], sink_path[1024];
int dm_online_d2s_completion_enabled(void) { return 1; }
void dm_online_d2s_completed(const char *path, uint64_t sequence, int reason) {
    if (reason == DM_SAVE_COMPLETION_CLOSE) {
        assert(sink_expected_closed_fd >= 0);
        errno = 0; assert(fcntl(sink_expected_closed_fd, F_GETFD) == -1 && errno == EBADF);
    }
    assert(sequence > sink_sequence); sink_sequence = sequence;
    ++sink_count; sink_reason = reason;
    snprintf(sink_path, sizeof sink_path, "%s", path);
    memset(sink_data, 0, sizeof sink_data);
    FILE *file = fopen(path, "rb"); assert(file);
    size_t n = fread(sink_data, 1, sizeof sink_data - 1, file); assert(n && !ferror(file)); fclose(file);
}
