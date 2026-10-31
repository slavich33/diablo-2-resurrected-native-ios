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
