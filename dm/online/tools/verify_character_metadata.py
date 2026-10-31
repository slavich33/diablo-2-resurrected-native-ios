#!/usr/bin/env python3
"""Original version-7 character-metadata decoder/encoder on synthetic inputs.

Desktop development reference only: no DLL entry point, OS, game, network or
character file is accessed. Stack probe, allocation/copy/fill/free and generic
vector append use bounded private-arena stand-ins. No semantic parser, validator
or metadata encoder is replaced. Requires the owner's exact core and Unicorn.
"""
from pathlib import Path
import argparse
import json
import os
import struct
from verify_reference_vectors import Reference, EXPECTED
from unicorn.x86_const import UC_X86_REG_RAX, UC_X86_REG_RCX, UC_X86_REG_RDX, UC_X86_REG_R8, UC_X86_REG_R9


class MetadataReference(Reference):
    def hook(self, mu, pc, size, user):
        rva = pc - self.base
        try:
            if rva == 0x537560:  # generic stack probe; private stack is preallocated
                self.ret(mu.reg_read(UC_X86_REG_RAX))
                return
            if rva in (0x53a4e0, 0x53a4f0):
                dst, src, count = map(mu.reg_read, (UC_X86_REG_RCX, UC_X86_REG_RDX, UC_X86_REG_R8))
                assert count <= 65536
                if count:
                    mu.mem_write(dst, bytes(mu.mem_read(src, count)))
                self.ret(dst)
                return
            if rva == 0x53a500:
                dst, value, count = map(mu.reg_read, (UC_X86_REG_RCX, UC_X86_REG_RDX, UC_X86_REG_R8))
                assert count <= 65536
                if count:
                    mu.mem_write(dst, bytes([value & 255]) * count)
                self.ret(dst)
                return
            if rva == 0x5136b8:
                count = mu.reg_read(UC_X86_REG_RCX)
                assert count <= 65536
                self.ret(self.alloc(count))
                return
            if rva == 0x286100:
                vec, pos, src, count = map(mu.reg_read, (UC_X86_REG_RCX, UC_X86_REG_RDX, UC_X86_REG_R8, UC_X86_REG_R9))
                assert count <= 65536
                self.append(vec, pos, src, count)
                self.ret()
                return
            if rva == 0x513710:
                self.ret()
                return
            super().hook(mu, pc, size, user)
        except Exception as error:
            self.problem = repr(error)
            mu.emu_stop()

    def canonical(self, data):
        assert len(data) <= 65536
        self.cursor = self.arena
        model = self.alloc(0x2080)
        self.mu.mem_write(model, bytes(0x2080))
        self.putq(model + 0x18, 15)  # empty std::string capacity
        accepted = bool(self.run(0x338b0, [self.span(data), model, 0]) & 255)
        if not accepted:
            return None
        output = self.vector()
        if not self.run(0x33530, [model, output, 0]) & 255:
            raise ValueError('Original accepted model could not be encoded')
        return self.readvec(output)


def wire(name=b'NativeFixture', version=7, checksum=0x12345678, size=403, edition=3,
         digest=bytes([42]) * 32, word50=0, word58=0, word60=0, word68=0, flag=0,
         first=b'', second=b''):
    return (bytes([version, len(name)]) + name + struct.pack('<IIB', checksum, size, edition)
            + digest + struct.pack('<QIQQB', word50, word58, word60, word68, flag)
            + struct.pack('<H', len(first)) + first + struct.pack('<H', len(second)) + second)


def cases():
    baseline = wire()
    result = [('baseline', baseline)]
    result += [(f'truncated-{n}', baseline[:n]) for n in range(len(baseline))]
    for field in ['version', 'edition', 'flag']:
        result += [(f'{field}-{n}', wire(**{field: n})) for n in range(256)]
    result += [(f'name-length-{n}', wire(name=bytes([65]) * n)) for n in [0, 1, 2, 15, 16, 61, 62, 63, 255]]
    for name in [b'\0', b'../x', bytes([255, 0, 128]), b'X\0Y']:
        result.append(('opaque-name-' + name.hex(), wire(name=name)))
    for size in [0, 1, 0xffffffff]:
        result.append((f'save-size-{size}', wire(size=size)))
    for checksum in [0, 1, 0xffffffff]:
        result.append((f'save-checksum-{checksum}', wire(checksum=checksum)))
    for digest in [bytes(32), bytes(31) + b'\1', b'\1' + bytes(31)]:
        result.append(('digest-' + digest.hex(), wire(digest=digest)))
    for word50 in range(66):
        result.append((f'zero-contract-{word50}', wire(word50=word50)))
        result.append((f'nonzero-contract-{word50}', wire(word50=word50, word58=1, word60=1, word68=1)))
    for word58 in [0, 1, 0xffffffff]:
        for first, last in [(0, 0), (0, 1), (1, 0), (1, 1), (2, 1), (2, 2), (1, 0xffffffffffffffff), (0xffffffffffffffff, 0xffffffffffffffff)]:
            result.append((f'contract-words-{word58}-{first}-{last}', wire(word50=1, word58=word58, word60=first, word68=last)))
    for field in ['first', 'second']:
        for count in [0, 1, 2, 255, 256, 4095, 4096, 4097]:
            result.append((f'{field}-nonzero-{count}', wire(**{field: bytes([43]) * count})))
            result.append((f'{field}-zero-{count}', wire(**{field: bytes(count)})))
    result.append(('two-full-blobs', wire(first=bytes([44]) * 4096, second=bytes([45]) * 4096)))
    result.append(('trim-zero-tails', wire(first=b'\1\0\2\0\0', second=b'\0\3\0')))
    for count in [1, 2, 100]:
        result.append((f'trailing-{count}', baseline + bytes(count)))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dll', required=True, type=Path)
    parser.add_argument('--vectors', type=Path)
    parser.add_argument('--output', type=Path, help='Create synthetic corpus mode0600 without overwriting')
    args = parser.parse_args()
    if not __debug__:
        parser.error('Run without -O: reference bounds require assertions')
    if args.dll.stat().st_size > 32 * 1024 * 1024:
        parser.error('Oversized original core')
    reference = MetadataReference(args.dll)
    results = []
    for label, data in cases():
        canonical = reference.canonical(data)
        results.append({'label': label, 'inputHex': data.hex(), 'accepted': canonical is not None,
                        'canonicalHex': canonical.hex() if canonical is not None else None})
    report = {'referenceSHA256': EXPECTED, 'scope': 'Synthetic version-7 wire parser/encoder only; no lineage/seal semantics, engine integration or sidecar support.',
              'cases': results, 'liveAdmissionVerified': False}
    if args.vectors is None and args.output is None:
        args.vectors = Path(__file__).resolve().parents[1] / 'Tests/ReimaginedClientTests/Fixtures/character-metadata-reference.json'
    if args.vectors:
        data = args.vectors.read_bytes()
        if len(data) > 8 * 1024 * 1024 or json.loads(data) != report:
            raise ValueError('Original character-metadata corpus mismatch')
    if args.output:
        fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'wb') as file:
            file.write((json.dumps(report, indent=2) + '\n').encode())
    print('Original metadata decoder/encoder:', len(results), 'synthetic cases;', sum(x['accepted'] for x in results), 'accepted; no sidecar support or admission.')


if __name__ == '__main__':
    main()
