#!/bin/bash
set -euo pipefail
D2R_ABI_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
D2R_ABI_REPO_ROOT="$(cd "$D2R_ABI_SCRIPT_DIR/../../../.." && pwd)"
D2R_ABI_SCRATCH="$(mktemp -d "${D2R_ABI_TMP_BASE:-${TMPDIR:-/tmp}}/d2r-native-tcp.XXXXXX")"
trap 'rm -rf "$D2R_ABI_SCRATCH"' EXIT
D2R_ABI_SDK="$(xcrun --sdk macosx --show-sdk-path)"
xcrun --sdk macosx clang -isysroot "$D2R_ABI_SDK" -Wall -Wextra -Werror -I "$D2R_ABI_REPO_ROOT/dm/ios/Sources" -c "$D2R_ABI_SCRIPT_DIR/probe.c" -o "$D2R_ABI_SCRATCH/probe.o"
xcrun --sdk macosx swiftc -sdk "$D2R_ABI_SDK" -parse-as-library -module-name NativeTCPCheck "$D2R_ABI_REPO_ROOT/dm/online/Sources/ReimaginedClient/GameTCPStream.swift" "$D2R_ABI_SCRATCH/probe.o" -o "$D2R_ABI_SCRATCH/probe"
"$D2R_ABI_SCRATCH/probe"
xcrun --sdk macosx clang -isysroot "$D2R_ABI_SDK" -Wall -Wextra -Werror -I "$D2R_ABI_REPO_ROOT/dm/ios/Sources" -c "$D2R_ABI_SCRIPT_DIR/packets.c" -o "$D2R_ABI_SCRATCH/packets.o"
xcrun --sdk macosx swiftc -sdk "$D2R_ABI_SDK" -parse-as-library -module-name NativePacketCheck \
 "$D2R_ABI_REPO_ROOT/dm/online/Sources/ReimaginedClient/ControlMessage.swift" \
 "$D2R_ABI_REPO_ROOT/dm/online/Sources/ReimaginedClient/LoaderFrame.swift" \
 "$D2R_ABI_REPO_ROOT/dm/online/Sources/ReimaginedClient/GamePacketStream.swift" \
 "$D2R_ABI_REPO_ROOT/dm/online/Sources/ReimaginedClient/StockServerPacketLengths.swift" \
 "$D2R_ABI_REPO_ROOT/dm/online/Sources/ReimaginedClient/GamePacketBridge.swift" \
 "$D2R_ABI_SCRATCH/packets.o" -o "$D2R_ABI_SCRATCH/packets"
"$D2R_ABI_SCRATCH/packets"
