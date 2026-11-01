#!/usr/bin/env python3
"""Bounded original full-table ItemStatCost environment-schema reference.

Executes only the original schema builder/name-cache lookup/hash on owned table
fixtures. The resource callback and uncontended locks use private stand-ins.
No OS, game entry point, network, character file or DLL entry point is invoked.
Production iOS uses native Swift; this desktop reference requires Unicorn.
"""
import argparse
import json
import os
import struct
from pathlib import Path
from unicorn.x86_const import UC_X86_REG_RCX, UC_X86_REG_RDX, UC_X86_REG_R8, UC_X86_REG_R9, UC_X86_REG_RSP, UC_X86_REG_RIP
from verify_character_stat_descriptors import StatReference
from verify_native_itemstatcost_schema import verify_native_schema
from verify_reference_vectors import EXPECTED


class SchemaReference(StatReference):
    def schema(self, edition, rows, names):
        assert edition in (1, 2, 3) and len(rows) % 324 == 0
        count = len(rows) // 324
        assert count <= 32768 and set(names) == set(range(count))
        assert all(0 < len(n) <= 1024 and b'\0' not in n for n in names.values())
        self.cursor = self.arena
        self.edition = edition
        self.manager = self.alloc(0x1300)
        self.mu.mem_write(self.manager, bytes(0x1300))
        self.putq(self.manager + 0x1258, self.rows)
        self.putq(self.manager + 0x1260, count)
        if rows:
            self.mu.mem_write(self.rows, rows)
        self.mu.mem_write(self.base + 0x7de2e0, bytes(4 * 24))
        for id, name in names.items():
            entry = self.names + 32 * id
            self.mu.mem_write(entry, bytes(32))
            if len(name) > 15:
                pointer = self.alloc(len(name) + 1)
                self.mu.mem_write(pointer, name + b'\0')
                self.putq(entry, pointer)
                self.putq(entry + 24, len(name))
            else:
                self.mu.mem_write(entry, name + b'\0')
                self.putq(entry + 24, 15)
            self.putq(entry + 16, len(name))
        self.mu.mem_write(self.base + 0x7de2e0 + 24 * edition,
                          struct.pack('<QQQ', self.names, self.names + 32 * count, self.names + 32 * count))
        out = self.alloc(8)
        self.putq(out, 0)
        stack = self.stack + 0xff008
        self.putq(stack, self.stop)
        for reg, value in zip((UC_X86_REG_RCX, UC_X86_REG_RDX, UC_X86_REG_R8, UC_X86_REG_R9), (edition, out, 0, 0)):
            self.mu.reg_write(reg, value)
        self.mu.reg_write(UC_X86_REG_RSP, stack)
        self.problem = None
        self.mu.emu_start(self.base + 0x3b75e0, self.stop, timeout=2_000_000, count=1_500_000)
        if self.problem or self.mu.reg_read(UC_X86_REG_RIP) != self.stop:
            raise ValueError(self.problem or 'Original schema did not return within bounds')
        from unicorn.x86_const import UC_X86_REG_RAX
        assert self.mu.reg_read(UC_X86_REG_RAX) & 255 == 1
        return self.q(out)


def cases():
    result = []
    def add(label, edition=3, rows=None, names=None):
        rows = [bytearray(324)] if rows is None else rows
        names = [f'own_stat_{i}' for i in range(len(rows))] if names is None else names
        result.append((label, edition, b''.join(rows), {i: n.encode('utf8') for i, n in enumerate(names)}))
    for edition in (1, 2, 3):
        for count in (0, 1, 2, 7, 17):
            add(f'edition-{edition}-rows-{count}', edition, [bytearray((i + j) % 256 for j in range(324)) for i in range(count)])
    for offset in (4, 0x18, 0x20):
        for value in (0, 1, 0xfff, 0x1000, 0x80000000, 0xffffffff):
            row = bytearray(324)
            struct.pack_into('<I', row, offset, value)
            add(f'word-{offset}-{value}', rows=[row])
    for offset in (0xa, 0xb, 0x14, 0x15):
        for value in (0, 1, 127, 255):
            row = bytearray(324); row[offset] = value
            add(f'byte-{offset}-{value}', rows=[row])
    for offset in (0, 3, 8, 0x16, 0x1c, 0x24, 323):
        row = bytearray(324); row[offset] = 255
        add(f'unrelated-column-{offset}', rows=[row])
    for name in ('x', 'a' * 15, 'a' * 16, 'a' * 64, 'a' * 1024, 'стат', '😀', 'Upper', 'upper'):
        add(f'name-{len(result)}', names=[name])
    add('ordered-first-second', rows=[bytearray(324)] * 2, names=['first', 'second'])
    add('ordered-second-first', rows=[bytearray(324)] * 2, names=['second', 'first'])
    return result


def read_capture(rows_path, names_path):
    if rows_path.stat().st_size > 32768 * 324 or names_path.stat().st_size > 32768 * 1032:
        raise ValueError('Oversized private capture')
    rows, data = rows_path.read_bytes(), names_path.read_bytes()
    names = {}; offset = 0
    while offset < len(data):
        if len(data) - offset < 8:
            raise ValueError('Truncated captured name header')
        id, size = struct.unpack_from('<II', data, offset); offset += 8
        if id in names or size == 0 or size > 1024 or size > len(data) - offset:
            raise ValueError('Invalid captured name')
        names[id] = data[offset:offset + size]; offset += size
    return rows, names


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dll', required=True, type=Path)
    parser.add_argument('--main', required=True, type=Path)
    parser.add_argument('--vectors', type=Path)
    parser.add_argument('--output', type=Path, help='Create a new mode0600 synthetic corpus; never overwrite')
    parser.add_argument('--captured-rows', type=Path)
    parser.add_argument('--captured-names', type=Path)
    parser.add_argument('--captured-edition', type=int, choices=(1, 2, 3), default=3)
    args = parser.parse_args()
    if not __debug__:
        parser.error('Run without -O; the bounded reference requires assertions')
    if bool(args.captured_rows) != bool(args.captured_names):
        parser.error('Supply both private capture paths')
    if args.dll.stat().st_size > 32 * 1024 * 1024:
        parser.error('Oversized original core')
    native = verify_native_schema(args.main)
    reference = SchemaReference(args.dll)
    records = []
    for label, edition, rows, names in cases():
        value = reference.schema(edition, rows, names)
        records.append({'label': label, 'edition': edition, 'rowsHex': rows.hex(),
                        'names': [names[i].decode('utf8') for i in range(len(names))], 'fingerprintHex': f'{value:016x}'})
    report = {'referenceSHA256': EXPECTED, 'nativeSchema': native,
              'scope': 'Full original ItemStatCost schema builder/name cache/hash on owned synthetic rows; no admission or game startup.',
              'cases': records, 'liveAdmissionVerified': False}
    if args.output is None and args.vectors is None:
        args.vectors = Path(__file__).resolve().parents[1] / 'Tests/ReimaginedClientTests/Fixtures/itemstatcost-environment-reference.json'
    if args.vectors:
        with args.vectors.open('rb') as file:
            data = file.read(8 * 1024 * 1024 + 1)
        if len(data) > 8 * 1024 * 1024 or json.loads(data) != report:
            raise ValueError('Original schema corpus mismatch')
    if args.output:
        with os.fdopen(os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'w') as file:
            json.dump(report, file, indent=2); file.write('\n')
    print('Original full-table schema:', len(records), 'synthetic cases matched; no admission or network.')
    if args.captured_rows:
        rows, names = read_capture(args.captured_rows, args.captured_names)
        value = reference.schema(args.captured_edition, rows, names)
        print('Private native capture:', len(rows) // 324, 'rows;', len(names), 'names; schema', f'{value:016x}')


if __name__ == '__main__':
    main()
