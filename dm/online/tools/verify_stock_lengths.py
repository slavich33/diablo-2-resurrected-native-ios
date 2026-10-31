#!/usr/bin/env python3
"""Read-only verification of native stock packet metadata against owned inputs.

No game function is executed. Does not validate variable lengths, TCP framing,
system routing, compression or gameplay admission. Inputs are never published.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import struct

import lz4.block
from check_engine_input import check

COUNT = 175
NATIVE_TABLE = 0x2081C28
WINDOWS_TABLE = 0x19C44A0
WINDOWS_SHA256 = "e1f5436e3d9687f644ef16938b1b183d1fdef434f18cf66d852cf68f48cc8936"


def native_sizes(path):
    proof = check(path)  # Pins the entire original engine, not a table alone.
    data = path.read_bytes()
    flags = struct.unpack_from("<I", data, 12)[0]
    for index in range(3):
        offset, address, size = struct.unpack_from("<III", data, 0x10 + index * 16)
        if not address <= NATIVE_TABLE or NATIVE_TABLE + COUNT * 24 > address + size:
            continue
        compressed = bool(flags & (1 << index))
        count = struct.unpack_from("<I", data, 0x60 + index * 4)[0] if compressed else size
        raw = data[offset:offset + count]
        segment = lz4.block.decompress(raw, uncompressed_size=size) if compressed else raw
        start = NATIVE_TABLE - address
        return [struct.unpack_from("<i", segment, start + i * 24 + 8)[0] for i in range(COUNT)], proof
    raise ValueError("Stock descriptors are outside verified segments")


def swift_sizes(path):
    source = path.read_text()
    match = re.search(r"private static let sizes: \[Int\] = \[(.*?)\n    \]", source, re.S)
    if not match:
        raise ValueError("Swift metadata declaration missing")
    body = re.sub(r"//[^\n]*", "", match.group(1))
    if not re.fullmatch(r"[\s,\d-]+", body):
        raise ValueError("Unexpected Swift metadata syntax")
    sizes = [int(value) for value in re.findall(r"-?\d+", body)]
    if len(sizes) != COUNT:
        raise ValueError("Wrong Swift metadata entry count")
    return sizes


def supported_variables(path):
    match = re.search(r"supportedVariableOpcodes: \[UInt8\] = \[([^\]]*)\]", path.read_text())
    if not match or not re.fullmatch(r"[0-9a-fx,\s]+", match.group(1)):
        raise ValueError("Swift supported-variable declaration missing")
    values = [int(value.strip(), 16) for value in match.group(1).split(',') if value.strip()]
    if len(values) != len(set(values)):
        raise ValueError("Duplicate variable declaration")
    return set(values)


def windows_sizes(path):
    if not 64 <= path.stat().st_size <= 512 * 1024 * 1024:
        raise ValueError("Windows reference size refused")
    data = path.read_bytes()
    if hashlib.sha256(data).hexdigest() != WINDOWS_SHA256:
        raise ValueError("Unsupported Windows reference; do not reuse RVAs")
    pe = struct.unpack_from("<I", data, 60)[0]
    if data[:2] != b"MZ" or data[pe:pe + 4] != b"PE\0\0":
        raise ValueError("Invalid Windows reference")
    section_count = struct.unpack_from("<H", data, pe + 6)[0]
    table = pe + 24 + struct.unpack_from("<H", data, pe + 20)[0]
    for index in range(section_count):
        _, rva, count, raw = struct.unpack_from("<IIII", data, table + index * 40 + 8)
        if rva <= WINDOWS_TABLE and WINDOWS_TABLE + COUNT * 24 <= rva + count:
            start = raw + WINDOWS_TABLE - rva
            return [struct.unpack_from("<i", data, start + i * 24 + 8)[0] for i in range(COUNT)]
    raise ValueError("Windows descriptors are outside file-backed sections")


def verify(main, source, windows=None):
    actual, proof = native_sizes(main)
    if swift_sizes(source) != actual:
        raise ValueError("Swift metadata differs from verified ARM64 engine")
    if any(length < -1 or length > 65536 for length in actual):
        raise ValueError("Invalid packet descriptor")
    if windows is not None and windows_sizes(windows) != actual:
        raise ValueError("Independent Windows metadata differs")
    supported = supported_variables(source)
    variable = {i for i, length in enumerate(actual) if length == -1}
    if not supported <= variable:
        raise ValueError("Supported-variable declaration differs from descriptors")
    return {
        "originalNSOVerified": proof["originalInputVerified"],
        "moduleID": proof["moduleID"],
        "swiftMetadataSHA256": hashlib.sha256(source.read_bytes()).hexdigest(),
        "entriesCompared": len(actual),
        "fixedLengthsVerified": sum(length > 0 for length in actual),
        "variableDescriptorCount": len(variable),
        "implementedVariableIDs": [f"0x{i:02x}" for i in sorted(supported)],
        "variableRulesVerifiedByMetadataAlone": False,
        "variableIDsStillUnsupported": [f"0x{i:02x}" for i in sorted(variable - supported)],
        "invalidZeroCount": actual.count(0),
        "independentWindowsMetadataMatched": windows is not None,
        "gameCodeExecuted": False,
        "transportFramingVerified": False,
        "gameAdmissionVerified": False,
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("main", type=Path, help="Original supported ARM64 ExeFS/main")
    parser.add_argument("--swift-source", type=Path, default=Path(__file__).resolve().parents[1] /
                        "Sources/ReimaginedClient/StockServerPacketLengths.swift")
    parser.add_argument("--windows-reference", type=Path, help="Optional pinned 3.3.93847 Windows image")
    args = parser.parse_args()
    try:
        print(json.dumps(verify(args.main, args.swift_source, args.windows_reference), indent=2))
    except (OSError, ValueError, struct.error, lz4.block.LZ4BlockError) as error:
        parser.exit(1, f"Stock metadata refused: {error}\n")
