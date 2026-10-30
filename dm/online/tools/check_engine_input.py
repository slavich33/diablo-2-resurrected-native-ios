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
