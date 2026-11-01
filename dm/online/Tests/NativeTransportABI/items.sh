#!/bin/bash
set -euo pipefail
D2R_ITEMS_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
D2R_ITEMS_ROOT="$(cd "$D2R_ITEMS_SCRIPT_DIR/../../../.." && pwd)"
D2R_ITEMS_TMP="$(mktemp -d "${D2R_ITEMS_TMP_BASE:-${TMPDIR:-/tmp}}/d2r-item-readers.XXXXXX")"
trap 'rm -rf "$D2R_ITEMS_TMP"' EXIT
for D2R_ITEMS_TEST in item_format item_format_gate net_state_packets net_state_gate; do
    D2R_ITEMS_SOURCES=("$D2R_ITEMS_ROOT/dm/host/dm_item_format.c")
    if [ "$D2R_ITEMS_TEST" = item_format_gate ]; then
        D2R_ITEMS_SOURCES+=("$D2R_ITEMS_ROOT/dm/host/hle_item_format.c")
    elif [[ "$D2R_ITEMS_TEST" = net_state* ]]; then
        D2R_ITEMS_SOURCES=("$D2R_ITEMS_ROOT/dm/host/dm_net_state_packets.c")
        if [ "$D2R_ITEMS_TEST" = net_state_gate ]; then
            D2R_ITEMS_SOURCES+=("$D2R_ITEMS_ROOT/dm/host/hle_net_state_packets.c")
        fi
    fi
    xcrun clang -std=c11 -Wall -Wextra -Werror -I "$D2R_ITEMS_ROOT/dm/host" \
        "${D2R_ITEMS_SOURCES[@]}" "$D2R_ITEMS_ROOT/dm/host/tests/t_$D2R_ITEMS_TEST.c" \
        -o "$D2R_ITEMS_TMP/$D2R_ITEMS_TEST"
    "$D2R_ITEMS_TMP/$D2R_ITEMS_TEST"
done
