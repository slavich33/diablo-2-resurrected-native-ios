#!/usr/bin/env python3
"""Read-only check of the original NSO input before developing engine adapters.

No patch is installed, no game code is executed, and no admission is granted.
Offsets below originate in the existing host/hle.h and host/diag.c hooks.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import lz4.block

MODULE = "db0507f36b84200ac05f75d76ed5026f903e6c90000000000000000000000000"
SEGMENT_HASHES = [
    "3f6001efbd7412c5a48c27a2b9514dc9178c3b69dd01007edd0d7456e09819a5",
    "e913be45ae39360093c823bb670e116461debef8592b61588c7f9ee8bc71ab0c",
    "6ebecf913070869f14f80f2908270b4891ddf969604507fa32e588fb78e93fd8",
]
ANCHORS = [
    ("command_delivery", 0x5D3A88, 0x632510, "d1ce4c04a734bc57b7202820c95f06182f674f399b21a794fafabfa3a983d467"),
    ("system_delivery", 0x5D39C8, 0x6310B0, "9dbfba30ab7d8615d1518e355be456b4817d6bd318da24c8c1ece15aaa5f8d4a"),
]
INDIRECT_ANCHORS = [
    ("client_send", 0x2CEC94, 8, "ac47aa837c7668c87613e35a52e4fb1c007c886c9f87a3e520e9e4108a281598"),
    ("client_receive", 0x2CFA5C, 9, "873b0242ffee7458d2494faf1d96f7d5c1d2da16c4c7ee3de21007190ded9141"),
]

ENTRY_ANCHORS = [
    ("system_queue", 0x8401c0, "fd7bbfa9fd030091", "8929a14be30a3d0a57fef86db0f510d78740b487ea1a912421a04fdf2fbd86f0"),
    ("game_queue", 0x840290, "fd7bbfa9fd030091", "2a1d55f8347cdbb2920044bd0807b28725e77ff717b9c246b92833189dd3101c"),
    ("client_send_queue", 0x840354, "f70f1cf8f65701a9", "9b0d731e1b8309a046929d36566cb368e58d0ef03abdc735d211901356a5d3f4"),
    ("client_connected", 0x841670, "f44fbea9fd7b01a9", "e938b7152d433b2104cdb76925ee7bdce176545e55e03b5d568c20cd6822a7d8"),
    ("client_failed", 0x841720, "08c04b3968000034", "9bd7ca5c532e7c8d1054d4a07c0431cb51e30a410a4ccad2404b8c1354c0737e"),
    ("client_hard_close", 0x83fe64, "081440b91f050071", "e2638f4918f81062bef994a649c6f767eade610c61cce48b106257bc7ac27029"),
    ("client_graceful_close", 0x83fe9c, "ff4301d1f65702a9", "768d23b1c7243253ad2b5b9de09f7c57f1b58b17dc33695dc6a9fca66f5a73b5"),
    ("client_connect", 0x8404d4, "fc6fbaa9fa6701a9", "9ac0d26c24624e30ac75bd8807fac119d6f09d9a6fc5af1d6f3d98a6da2f1c5d"),
    ("client_start", 0x841568, "ff0301d1f44f02a9", "c47dcf31c248f09a3da02476c1b585df2b69d4ca3c1ef5f8dc3117466ac1147c"),
    ("client_idle", 0x841740, "081440b91f050071", "734723d8eb82507ea5d7843e8f4ba9b2359747030f8ecfb2afee683a9c5292ec"),
]


def check(path):
    with path.open("rb") as source:
        data = source.read(64 * 1024 * 1024 + 1)
    if not 0x100 <= len(data) <= 64 * 1024 * 1024 or data[:4] != b"NSO0":
        raise ValueError("Invalid or oversized NSO input")
    if data[0x40:0x60].hex() != MODULE:
        raise ValueError("Unsupported engine module; no hooks may be enabled")
    flags = struct.unpack_from("<I", data, 12)[0]
    compressed_sizes = struct.unpack_from("<III", data, 0x60)
    segments = []
    total = 0
    for index, expected in enumerate(SEGMENT_HASHES):
        offset, address, size = struct.unpack_from("<III", data, 0x10 + index * 16)
        count = compressed_sizes[index] if flags & (1 << index) else size
        total += size
        if size > 64 * 1024 * 1024 or total > 128 * 1024 * 1024 or offset < 0x100 or count > len(data) - offset:
            raise ValueError("Invalid NSO segment bounds")
        raw = data[offset:offset + count]
        decoded = lz4.block.decompress(raw, uncompressed_size=size) if flags & (1 << index) else raw
        digest = hashlib.sha256(decoded).hexdigest()
        if len(decoded) != size or digest != expected:
            raise ValueError("Engine segment does not match the supported build")
        if flags & (1 << (index + 3)) and bytes.fromhex(digest) != data[0xA0 + index * 32:0xC0 + index * 32]:
            raise ValueError("NSO segment header hash mismatch")
        segments.append((address, decoded))
    if segments[0][0] != 0:
        raise ValueError("Unexpected text mapping")
    text = segments[0][1]
    result = {"engineVersion": "3.3.94012", "moduleID": MODULE,
              "inputSha256": hashlib.sha256(data).hexdigest(), "originalInputVerified": True,
              "runtimeVerified": False, "hooksInstalled": False, "gameAdmissionVerified": False, "anchors": []}
    for name, site, target, expected in ANCHORS:
        instruction = struct.unpack_from("<I", text, site)[0]
        delta = instruction & 0x3FFFFFF
        if delta & (1 << 25):
            delta -= 1 << 26
        actual = site + 4 * delta
        if instruction >> 26 != 0b100101 or actual != target or hashlib.sha256(text[site - 16:site + 20]).hexdigest() != expected:
            raise ValueError("Engine call-site window does not match")
        result["anchors"].append({"name": name, "moduleOffset": hex(site), "targetOffset": hex(target), "windowSha256": expected})
    for name, site, register, expected in INDIRECT_ANCHORS:
        instruction = struct.unpack_from("<I", text, site)[0]
        if instruction != (0xD63F0000 | (register << 5)) or hashlib.sha256(text[site - 16:site + 20]).hexdigest() != expected:
            raise ValueError("Engine virtual-call window does not match")
        result["anchors"].append({"name": name, "moduleOffset": hex(site),
                                  "targetRegister": register, "windowSha256": expected})
    for name, site, prologue, expected in ENTRY_ANCHORS:
        if text[site:site + 8].hex() != prologue or hashlib.sha256(text[site - 16:site + 20]).hexdigest() != expected:
            raise ValueError("Engine method window does not match")
        result["anchors"].append({"name": name, "moduleOffset": hex(site), "windowSha256": expected})
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("main", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        document = json.dumps(check(args.main), indent=2) + "\n"
        if args.output:
            args.output.write_text(document)
        else:
            print(document, end="")
    except (OSError, ValueError, struct.error, lz4.block.LZ4BlockError) as error:
        parser.exit(1, f"Engine input rejected: {error}\n")
