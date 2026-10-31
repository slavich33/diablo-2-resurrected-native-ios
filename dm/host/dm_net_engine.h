#pragma once
#include <stdint.h>

// Exact-build development hooks. Both forward to the original virtual method.
// They do not select a remote role, attach TCP, admit a player or touch saves.
void svc_net_client_send(uint64_t *regs);
void svc_net_client_poll(uint64_t *regs);
