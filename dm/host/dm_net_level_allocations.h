#pragma once
#include <stdint.h>

/* Record only the exact object-data allocation expanded by the optional
 * peer adapter. Remove it before the original allocator releases the pointer.
 * No caller may infer allocation size from a network packet or unit tag. */
int dm_net_level_allocation_add(const void *pointer);
int dm_net_level_allocation_has(const void *pointer);
void dm_net_level_allocation_remove(const void *pointer);
