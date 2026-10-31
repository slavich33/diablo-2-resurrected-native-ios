#!/usr/bin/env python3
"""Bounded offline ARM64 start/status reference; never runs an OS or game entry.

Requires the owner's original, pinned NSO and development-only Unicorn/lz4.
The resolver, clock and generic pending-request storage are isolated stand-ins.
This proves lifecycle ordering, not actual network resolution or admission.
"""
import argparse
import json
from pathlib import Path
import struct

import lz4.block
from unicorn import Uc, UC_ARCH_ARM64, UC_MODE_ARM, UC_HOOK_CODE
from unicorn.arm64_const import (
    UC_ARM64_REG_X0, UC_ARM64_REG_X1, UC_ARM64_REG_X2,
    UC_ARM64_REG_SP, UC_ARM64_REG_LR, UC_ARM64_REG_PC,
)

from check_engine_input import check


def verify(path: Path) -> dict:
    check(path)  # Exact module ID, all segment hashes and lifecycle windows.
    data = path.read_bytes()
    flags = struct.unpack_from('<I', data, 12)[0]
    cpu = Uc(UC_ARCH_ARM64, UC_MODE_ARM)
    for index in range(3):
        offset, address, size = struct.unpack_from('<III', data, 16 + index * 16)
        compressed = bool(flags & (1 << index))
        count = struct.unpack_from('<I', data, 0x60 + 4 * index)[0] if compressed else size
        segment = data[offset:offset + count]
        if compressed:
            segment = lz4.block.decompress(segment, uncompressed_size=size)
        cpu.mem_map(address, (size + 4095) & ~4095)
        cpu.mem_write(address, segment)

    arena, stack, stop = 0x40000000, 0x50000000, 0x60000000
    cpu.mem_map(arena, 0x100000)
    cpu.mem_map(stack, 0x10000)
    cpu.mem_map(stop, 4096)
    client, backend = arena, arena + 0x30000
    reference, name, cell = arena + 0x40000, arena + 0x40100, arena + 0x50000
    now = 100000000
    resolver_calls = []

    def put64(address, value):
        cpu.mem_write(address, struct.pack('<Q', value))

    def put32(address, value):
        cpu.mem_write(address, struct.pack('<I', value))

    def return_value(value):
        cpu.reg_write(UC_ARM64_REG_X0, value)
        cpu.reg_write(UC_ARM64_REG_PC, cpu.reg_read(UC_ARM64_REG_LR))

    def hook(_cpu, pc, _size, _user):
        if pc == 0x1b77320:
            # No DNS/OS call: observe the original resolver request only.
            if cpu.reg_read(UC_ARM64_REG_X1) != name:
                raise ValueError('Unexpected resolver input')
            resolver_calls.append(cpu.reg_read(UC_ARM64_REG_X0))
            put32(cpu.reg_read(UC_ARM64_REG_X2), 0)
            return_value(0)
        elif pc in (0x1b76ae0, 0x1b76af0):
            return_value(now)
        elif pc == 0x840058:
            return_value(cell)  # Per-reference bounded pending-request storage.
        elif not 0x841568 <= pc < 0x841720:
            raise ValueError(f'Unapproved reference call: {pc:#x}')

    cpu.hook_add(UC_HOOK_CODE, hook)

    def run(entry, *args):
        for register, value in zip((UC_ARM64_REG_X0, UC_ARM64_REG_X1, UC_ARM64_REG_X2), args):
            cpu.reg_write(register, value)
        cpu.reg_write(UC_ARM64_REG_SP, stack + 0xff00)
        cpu.reg_write(UC_ARM64_REG_LR, stop)
        cpu.emu_start(entry, stop, timeout=1000000, count=5000)
        if cpu.reg_read(UC_ARM64_REG_PC) != stop:
            raise ValueError('Reference did not return within bounds')
        return cpu.reg_read(UC_ARM64_REG_X0)

    put64(client + 0x20328, backend)
    put64(reference, name)
    cpu.mem_write(name, b'127.0.0.1\0')
    run(0x841568, client, reference, 4000)
    state = struct.unpack('<I', cpu.mem_read(client + 0x14, 4))[0]
    if state != 2 or resolver_calls != [2]:
        raise ValueError('Original start path did not request the expected backend')
    if run(0x841670, client) != 0:
        raise ValueError('Pending backend incorrectly reported connected')

    # Model backend completion without invoking the original connect method.
    put64(client + 0x20, 1)
    put64(client + 0x28, now)
    if run(0x841670, client) != 1:
        raise ValueError('Completed start backend still requires connect')
    cpu.mem_write(client + 0x2f0, b'\1')
    if run(0x841670, client) != 0:
        raise ValueError('Failed backend incorrectly reported connected')
    return {
        'originalInputVerified': True,
        'startState': state,
        'connectedBeforeBackendCompletion': False,
        'connectedAfterBackendCompletion': True,
        'connectedAfterBackendFailure': False,
        'connectMethodInvocations': 0,
        'osNetworkEntryPointInvocations': 0,
        'remoteAdmissionVerified': False,
    }


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('main', type=Path, help='Original supported NSO, never uploaded')
    args = parser.parse_args()
    print(json.dumps(verify(args.main), indent=2))
