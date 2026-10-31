#!/bin/bash
set -euo pipefail
D2R_TABLE_TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
D2R_TABLE_REPO="$(cd "$D2R_TABLE_TEST_DIR/../../../.." && pwd)"
D2R_TABLE_SCRATCH="$(mktemp -d "${D2R_ABI_TMP_BASE:-${TMPDIR:-/tmp}}/d2r-native-tables.XXXXXX")"
trap 'rm -rf "$D2R_TABLE_SCRATCH"' EXIT
xcrun clang -O1 -Wall -Wextra -Werror -I "$D2R_TABLE_REPO/dm/host" -c "$D2R_TABLE_TEST_DIR/tables.c" -o "$D2R_TABLE_SCRATCH/fixture.o"
xcrun clang -O1 -Wall -Wextra -Werror -I "$D2R_TABLE_REPO/dm/host" -c "$D2R_TABLE_REPO/dm/host/hle_net_tables.c" -o "$D2R_TABLE_SCRATCH/tables.o"
xcrun swiftc -parse-as-library -import-objc-header "$D2R_TABLE_REPO/dm/host/dm_net_tables.h" \
 "$D2R_TABLE_REPO"/dm/online/Sources/ReimaginedClient/*.swift \
 "$D2R_TABLE_REPO/dm/ios/Sources/dm_online_tables.swift" "$D2R_TABLE_TEST_DIR/tables.swift" \
 "$D2R_TABLE_SCRATCH/fixture.o" "$D2R_TABLE_SCRATCH/tables.o" -o "$D2R_TABLE_SCRATCH/check"
"$D2R_TABLE_SCRATCH/check"
