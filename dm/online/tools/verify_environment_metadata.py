#!/usr/bin/env python3
"""Full pinned original D2EM parser/validator on own optional-metadata fixtures.

Only private-arena allocation, copy, free and memcmp are substituted. No OS,
network, game entry point or original data is distributed. Not admission proof.
"""
import argparse
import json
import os
import struct
from pathlib import Path
from verify_environment_description import EnvReference, baseline
from verify_reference_vectors import EXPECTED


def text(value):
    return struct.pack('<H', len(value)) + value


def mod(texts=(b'mod', b'version', b'path', b'four'), word=7, flag=1):
    return b''.join(map(text, texts)) + struct.pack('<IB', word, flag)


def plugin(texts=(b'plugin', b'version', b'path', b'file'), role=1, scope=2,
           first=3, second=4, digest=b''):
    return b''.join(map(text, texts)) + struct.pack('<BBIIB', role, scope, first, second, len(digest)) + digest


def inventory(entries):
    return struct.pack('<H', len(entries)) + b''.join(entries)


def frame(optional):
    fields = [(i + 1 | 0x8000, d) for i, d in enumerate(baseline())] + optional
    body = b''.join(struct.pack('<HI', i, len(d)) + d for i, d in fields)
    assert len(body) <= 65526
    return b'D2EM\3\0' + struct.pack('<I', len(body)) + body


def read_metadata(r, model, present):
    def string(address):
        length, capacity = r.q(address + 16), r.q(address + 24)
        assert length <= 1024
        pointer = r.q(address) if capacity >= 16 else address
        assert r.arena <= pointer <= r.cursor and length <= r.cursor - pointer
        return bytes(r.mu.mem_read(pointer, length)).hex()
    roots = [string(model + i) for i in (8, 40)] if 16 in present else None
    result_mod = None
    if 17 in present:
        assert bytes(r.mu.mem_read(model + 0xf0, 1)) == b'\1'
        word, flag = struct.unpack('<IB', r.mu.mem_read(model + 0xe8, 5))
        result_mod = dict(texts=[string(model + 0x68 + 32 * i) for i in range(4)], word=word, flag=bool(flag))
    entries = None
    if 18 in present:
        start, end, capacity = struct.unpack('<QQQ', r.mu.mem_read(model + 0x110, 24))
        assert start <= end <= capacity and (end - start) % 0xb0 == 0 and end - start <= 256 * 0xb0
        assert start == end or (r.arena <= start <= end <= r.cursor)
        entries = []
        for address in range(start, end, 0xb0):
            role, scope = bytes(r.mu.mem_read(address + 0x80, 2))
            first, second = struct.unpack('<II', r.mu.mem_read(address + 0x84, 8))
            has_digest = bytes(r.mu.mem_read(address + 0xac, 1)) == b'\1'
            entries.append(dict(texts=[string(address + 32 * i) for i in range(4)], role=role, scope=scope,
                                word84=first, word88=second,
                                digest=bytes(r.mu.mem_read(address + 0x8c, 32)).hex() if has_digest else None))
    return dict(rootTexts=roots, mod=result_mod, plugins=entries)


def cases():
    result = [('absent', [])]
    samples = [(16, text(b'root') + text(b'build')), (17, mod()), (18, inventory([plugin()]))]
    for field, payload in samples:
        result.append((f'field{field}-valid', [(field, payload)]))
        for count in range(len(payload)):
            result.append((f'field{field}-truncated-{count}', [(field, payload[:count])]))
        result.append((f'field{field}-trailing', [(field, payload + b'\0')]))
    result.append(('all', samples))
    for index in range(2):
        for length in (0, 1, 15, 16, 1023, 1024, 1025):
            values = [b'root', b'build']; values[index] = bytes([65 + index]) * length
            result.append((f'root{index}-length{length}', [(16, b''.join(map(text, values)))]))
    for field in (16, 17, 18):
        for value in (b'\xff', b'\xc3\xa9', b'a\0b'):
            payload = text(value) + text(b'') if field == 16 else mod((value, b'v', b'p', b'f')) if field == 17 else inventory([plugin((value, b'v', b'p', b'f'))])
            result.append((f'field{field}-raw{value.hex()}', [(field, payload)]))
    for index in range(4):
        for length in (0, 15, 16, 1024, 1025):
            values = [b'mod', b'version', b'path', b'four']; values[index] = b'M' * length
            result.append((f'mod{index}-length{length}', [(17, mod(values))]))
            values = [b'plugin', b'version', b'path', b'file']; values[index] = b'P' * length
            result.append((f'plugin{index}-length{length}', [(18, inventory([plugin(values)]))]))
    for flag in (0, 1, 2, 255):
        for word in (0, 1, 0xffffffff):
            result.append((f'mod-flag{flag}-word{word}', [(17, mod(flag=flag, word=word))]))
    for role in (0, 1, 2, 3, 255):
        for scope in (0, 1, 2, 3, 4, 255):
            result.append((f'plugin-role{role}-scope{scope}', [(18, inventory([plugin(role=role, scope=scope)]))]))
    for length in (0, 1, 31, 32, 33, 255):
        result.append((f'plugin-digest{length}', [(18, inventory([plugin(digest=b'D' * length)]))]))
    result.append(('plugin-zero-digest', [(18, inventory([plugin(digest=bytes(32))]))]))
    for first in (0, 0xffffffff):
        for second in (0, 0xffffffff):
            result.append((f'plugin-words{first}-{second}', [(18, inventory([plugin(first=first, second=second)]))]))
    result += [('empty-plugins', [(18, b'\0\0')]), ('overflow-plugins', [(18, struct.pack('<H', 257))])]
    for role in (1, 2):
        for scope in (1, 2, 3):
            result.append((f'duplicate-role{role}-scope{scope}', [(18, inventory([plugin(), plugin(role=role, scope=scope)]))]))
    result.append(('unordered', [(18, inventory([plugin((b'z', b'', b'', b'f')), plugin((b'a', b'', b'', b'f'))]))]))
    for first, second in [(b'a', b'ab'), (b'ab', b'a'), (b'A', b'a'), (b'a', b'A'),
                          (b'a\0', b'a\0b'), (b'a\0b', b'a\0'), (b'\xfe', b'\xff'), (b'\xff', b'\xfe')]:
        result.append((f'order-{first.hex()}-{second.hex()}', [(18, inventory([
            plugin((first, b'', b'', b'f')), plugin((second, b'', b'', b'f'))]))]))
    for first, second in [(1, 2), (2, 1), (1, 1), (2, 2)]:
        result.append((f'role-order-{first}-{second}', [(18, inventory([
            plugin((b'z', b'', b'', b'f'), role=first), plugin((b'a', b'', b'', b'f'), role=second)]))]))
    result.append(('sixteen-plugins', [(18, inventory([plugin((f'item{i:02d}'.encode(), b'', b'', b'f')) for i in range(16)]))]))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dll', required=True, type=Path)
    parser.add_argument('--vectors', type=Path)
    parser.add_argument('--output', type=Path, help='Create own corpus, never overwrite')
    args = parser.parse_args()
    if not __debug__: parser.error('Run without -O')
    if args.dll.stat().st_size > 32 * 1024 * 1024: parser.error('Oversized original core')
    r = EnvReference(args.dll)
    results = []
    for label, fields in cases():
        data = frame(fields); r.cursor = r.arena
        inp = r.alloc(len(data)); r.mu.mem_write(inp, data)
        out = r.alloc(0x540); r.mu.mem_write(out, bytes(0x500) + b'\xa7' * 0x40)
        accepted = bool(r.run(0x2f7c0, [inp, len(data), out, 0], [0]) & 255)
        assert bytes(r.mu.mem_read(out + 0x500, 0x40)) == b'\xa7' * 0x40
        results.append(dict(label=label, envelopeHex=data.hex(), accepted=accepted,
                            metadata=read_metadata(r, out, {i for i, _ in fields}) if accepted else None))
    report = dict(referenceSHA256=EXPECTED, scope='Full original parser/local validator and decoded optional metadata16..18 on own synthetic bytes; not provenance/admission.',
                  cases=results, liveAdmissionVerified=False)
    if not args.vectors and not args.output:
        args.vectors = Path(__file__).resolve().parents[1] / 'Tests/ReimaginedClientTests/Fixtures/environment-metadata-reference.json'
    if args.vectors:
        raw = args.vectors.read_bytes(); assert len(raw) <= 8 * 1024 * 1024
        if json.loads(raw) != report: raise ValueError('Original environment-metadata corpus mismatch')
    if args.output:
        fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'w') as f: json.dump(report, f, indent=2); f.write('\n')
    print('Original optional environment metadata:', len(results), 'synthetic cases;', sum(x['accepted'] for x in results), 'accepted; no admission.')


if __name__ == '__main__':
    main()
