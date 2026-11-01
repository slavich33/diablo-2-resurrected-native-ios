#!/usr/bin/env python3
"""Capture exact-build ARM64 counted producers with synthetic dependencies.

Runs only the bounded producer, with in-memory memcpy/memset, a synthetic unit
lookup and a recording send sink. No game entry, OS, account, device, network or
save API executes. Output contains synthetic bytes in an explicit scratch path;
never commit original images or private capture files.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import sys

from unicorn import Uc, UC_ARCH_ARM64, UC_MODE_ARM, UC_HOOK_CODE
from unicorn.arm64_const import (
    UC_ARM64_REG_X0, UC_ARM64_REG_X1, UC_ARM64_REG_X2,
    UC_ARM64_REG_X30, UC_ARM64_REG_SP, UC_ARM64_REG_PC,
)
from unicorn import arm64_const

from check_engine_input import check


def capture(main, scratch):
    if scratch.exists():
        raise ValueError("Refuse to replace an existing capture directory")
    proof = check(main)
    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "verify"))
    from nsoimg import load

    image = load(main)
    cpu = Uc(UC_ARCH_ARM64, UC_MODE_ARM)
    cpu.mem_map(0, (len(image) + 4095) & ~4095)
    cpu.mem_write(0, image)
    objects, data, stack, vtable, trap = (
        0x20000000, 0x21000000, 0x22000000, 0x23000000, 0x24000000)
    for base in (objects, data, stack, vtable, trap):
        cpu.mem_map(base, 0x10000)
    world = 0x25000000
    cpu.mem_map(world, 0x20000)
    client, subject, unit = objects, objects + 0x2000, objects + 0x4000
    path = objects + 0x6000
    stop = trap + 0x100

    def putq(address, value):
        cpu.mem_write(address, struct.pack("<Q", value))

    putq(0x2d7f3d8, vtable)
    putq(vtable + 0x28, trap)
    putq(subject + 0x9b0, data)
    putq(subject + 0x9b8, 255)
    sent = []

    def return_to_caller(value=None):
        if value is not None:
            cpu.reg_write(UC_ARM64_REG_X0, value)
        cpu.reg_write(UC_ARM64_REG_PC, cpu.reg_read(UC_ARM64_REG_X30))

    def hook(_cpu, pc, _size, _context):
        a, b, count = (cpu.reg_read(reg) for reg in (
            UC_ARM64_REG_X0, UC_ARM64_REG_X1, UC_ARM64_REG_X2))
        if pc == 0x5d7e60:
            if a not in (client, subject) or b != 0:
                raise ValueError("Unexpected producer dependency")
            return_to_caller(unit)
        elif pc in (0x1b76040, 0x1b76050):
            if count > 4096:
                raise ValueError("Unbounded synthetic memory dependency")
            payload = bytes(cpu.mem_read(b, count)) if pc == 0x1b76040 else bytes([b & 255]) * count
            if payload:
                cpu.mem_write(a, payload)
            return_to_caller(a)
        elif pc == trap:
            if a != 0x2d7f3d8:
                raise ValueError("Unexpected send dependency")
            begin, end = struct.unpack("<QQ", cpu.mem_read(count, 16))
            if not 7 <= end - begin <= 262:
                raise ValueError("Unbounded producer output")
            sent.append(bytes(cpu.mem_read(begin, end - begin)))
            return_to_caller()
        elif not (0x5d3170 <= pc < 0x5d3358 or 0x63dc70 <= pc < 0x63e2f0):
            raise ValueError(f"Unapproved producer call {pc:#x}")

    cpu.hook_add(UC_HOOK_CODE, hook)
    records = []

    def reset(arguments):
        cpu.mem_write(stack, bytes(0x10000))
        sent.clear()
        for index in range(30):
            cpu.reg_write(getattr(arm64_const, f"UC_ARM64_REG_X{index}"), 0)
        cpu.reg_write(UC_ARM64_REG_SP, stack + 0xff00)
        cpu.reg_write(UC_ARM64_REG_X30, stop)
        for index, value in enumerate(arguments):
            cpu.reg_write(getattr(arm64_const, f"UC_ARM64_REG_X{index}"), value)

    def execute(start, opcode, length, count_offset, count):
        cpu.emu_start(start, stop, timeout=100_000, count=10_000)
        if cpu.reg_read(UC_ARM64_REG_PC) != stop or len(sent) != 1:
            raise ValueError("Producer did not return exactly one packet")
        packet = sent[0]
        if packet[0] != opcode or packet[count_offset] != count or len(packet) != length:
            raise ValueError("Original producer's counted boundary changed")
        records.append(dict(sequence=len(records) + 1, direction="s2c-game", id=opcode,
                            length=len(packet), payload=packet.hex()))

    for payload_count in range(256):
        # The source object's byte span is255 bytes. The original producer
        # pads its temporary span; its own third byte supplies the packet count.
        source = bytes([0x41, 0x7d, payload_count]) + bytes(
            (i * 37 + payload_count) & 255 for i in range(252))
        cpu.mem_write(data, source)
        cpu.mem_write(unit + 8, struct.pack("<I", 0x12340000 + payload_count))
        reset([objects + 0x6000, client, subject])
        execute(0x5d3170, 0x78, 7 + payload_count, 6, payload_count)
        if bytes(cpu.mem_read(data, len(source))) != source:
            raise ValueError("Producer changed the input source")
    # The two path producers include a two-byte batch trailer before four-byte
    # records. Test all raw path-count bytes and independent pagination values,
    # including empty, partial, saturated and exhausted batches.
    unit_id = 0x12340042
    putq(client + 0x2e0, world)
    putq(world + 0x2630 + (unit_id & 0x7f) * 8, unit)
    cpu.mem_write(unit, struct.pack("<I", 0))
    cpu.mem_write(unit + 8, struct.pack("<I", unit_id))
    putq(unit + 0x38, path)
    cpu.mem_write(path + 0xc8, bytes((i * 19 + 3) & 255 for i in range(2048)))
    for opcode, start, header in ((0x71, 0x63dc70, 23), (0x72, 0x63dea0, 22)):
        for raw_count in range(256):
            for page in (0, 1, 2, 17):
                cpu.mem_write(path + 0x34, bytes([raw_count]))
                cpu.mem_write(path + 0xb8, struct.pack("<I", page))
                arguments = ([client, 0x41, unit_id, 0x1234, 0x5678, 9, 10, 11]
                             if opcode == 0x71 else
                             [client, 0x41, unit_id, 6, 0x87654321, 0x1234, 0x5678, 11])
                reset(arguments)
                cpu.mem_write(stack + 0xff00, struct.pack("<Q", 0x2468))
                cpu.mem_write(stack + 0xff08, bytes([0x57]))
                count = min(15, max(0, raw_count - 15 * page))
                before_path = bytes(cpu.mem_read(path, 0x1000))
                execute(start, opcode, header + 4 * count, header - 2, count)
                if bytes(cpu.mem_read(path, 0x1000)) != before_path:
                    raise ValueError("Producer changed the source path")
    scratch.mkdir(parents=True, exist_ok=False)
    capture_path = scratch / "counted-producers.private.jsonl"
    capture_path.write_text("".join(json.dumps(record) + "\n" for record in records))
    capture_path.chmod(0o600)
    report = dict(originalNSOVerified=proof["originalInputVerified"],
                  cases=len(records), payloadCountValuesChecked=256,
                  pathCountValuesChecked=256, pathPagesChecked=[0, 1, 2, 17],
                  opcodes=["0x71", "0x72", "0x78"],
                  allOriginalProducerBoundariesMatched=True, sourceUnchanged=True,
                  captureSHA256=hashlib.sha256(capture_path.read_bytes()).hexdigest(),
                  syntheticDependenciesOnly=True, gameEntryInvocations=0,
                  osNetworkCalls=0, gameAdmissionVerified=False)
    (scratch / "proof.private.json").write_text(json.dumps(report, indent=2) + "\n")
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("main", type=Path)
    parser.add_argument("--scratch", type=Path, required=True)
    arguments = parser.parse_args()
    print(json.dumps(capture(arguments.main, arguments.scratch), indent=2))
