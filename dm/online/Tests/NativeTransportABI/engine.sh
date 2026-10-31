#!/bin/bash
set -euo pipefail
D2R_ENGINE_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
D2R_ENGINE_ROOT="$(cd "$D2R_ENGINE_SCRIPT_DIR/../../../.." && pwd)"
D2R_ENGINE_TMP="$(mktemp -d "${D2R_ENGINE_TMP_BASE:-${TMPDIR:-/tmp}}/d2r-engine-abi.XXXXXX")"
trap 'rm -rf "$D2R_ENGINE_TMP"' EXIT
xcrun clang -arch arm64 -O1 -Wall -Wextra -Werror \
 "$D2R_ENGINE_ROOT/dm/host/hle_net_engine.c" \
 "$D2R_ENGINE_ROOT/dm/host/tests/t_net_engine_abi.c" \
 "$D2R_ENGINE_ROOT/dm/host/tests/net_engine_abi_fixture.S" \
 -o "$D2R_ENGINE_TMP/probe"
"$D2R_ENGINE_TMP/probe" "$D2R_ENGINE_TMP/trace.jsonl"
