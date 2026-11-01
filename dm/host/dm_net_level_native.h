#pragma once
#include <stdint.h>
void svc_net_level_entry(uint64_t *regs, unsigned char *base, uint32_t opcode);
int svc_net_level_field(uint64_t *regs, unsigned char *base, uint64_t site);
void svc_net_level_length(uint64_t *regs);
