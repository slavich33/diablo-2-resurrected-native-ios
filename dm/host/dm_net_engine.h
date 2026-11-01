#pragma once
#include <stdint.h>

// Legacy call-site handlers for earlier diagnostic products.
// They forward the original virtual method.
void svc_net_client_send(uint64_t *regs);
void svc_net_client_poll(uint64_t *regs);
// Queue entries: bound clients use native packet FIFOs; other clients resume
// the original method at the independently checked entry+8. No role/admission
// or save-mount transition is performed by these methods.
void svc_net_queue_send(uint64_t *regs, uint64_t original_body);
void svc_net_queue_poll(uint64_t *regs, uint64_t original_body, int gameplay);
// Status/close methods have x0 only. Unbound paths resume exact displaced
// instructions, including the leaf failed-status method's conditional branch.
void svc_net_client_status(uint64_t *regs, uint64_t original_body, int failed);
void svc_net_client_close(uint64_t *regs, uint64_t original_body, int graceful);
// Conditional entry gate, not C forwarding: x0..x7 and the ninth stack argument
// remain on the original caller's stack. Only x8 is a temporary branch result.
void svc_net_connect_guard(uint64_t *regs);
void svc_net_start_guard(uint64_t *regs);
void svc_net_bootstrap_guard(uint64_t *regs, uint64_t client);
void svc_net_client_idle(uint64_t *regs, uint64_t original_body);
// Per-frame session monitor. An isolated bound lane uses its coordinator-owned
// connection state; unbound calls invoke the original one-argument monitor.
// This is connection health, not a server game-admission acknowledgement.
void svc_net_session_poll(uint64_t *regs, uint64_t original_target, uint64_t client);
