#!/usr/bin/env python3
"""Original v2 sidecar signing digest on own synthetic fixtures only.

Runs the full original validator, signing-mode payload writer and SHA256.
No Windows key, signer, OS, game, account or network function is executed.
"""
from pathlib import Path
import argparse, hashlib, json, os, struct
from verify_character_sidecar import SidecarReference, cases, prefix, file, body, plugin, stat
from verify_reference_vectors import EXPECTED

class SigningReference(SidecarReference):
    def signing_digest(self, model):
        before = bytes(self.mu.mem_read(model, 0x280))
        output = self.alloc(32); error = self.alloc(4)
        self.mu.mem_write(error, bytes(4))
        ok = bool(self.run(0x8fd0, [model, output, error]) & 255)
        status = struct.unpack('<I', self.mu.mem_read(error, 4))[0]
        if not ok or status: raise ValueError('Original signing hash refused valid fixture')
        if bytes(self.mu.mem_read(model, 0x280)) != before: raise ValueError('Original signing hash modified its model or allocation guard')
        return bytes(self.mu.mem_read(output, 32))

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dll', type=Path, required=True)
    parser.add_argument('--vectors', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if not __debug__: parser.error('Bounded reference requires assertions; run without -O')
    if args.dll.stat().st_size > 32 * 1024 * 1024: parser.error('Oversized original core')
    r = SigningReference(args.dll)
    domain = bytes(r.mu.mem_read(r.base + 0x53ea90, 13))
    assert domain == b'D2RL-SEAL-V2\0'
    inputs = list(cases)
    for signature in [1, 2, 255]:
        for key in [1, 2, 255]:
            p = prefix(); struct.pack_into('<I', p, 120, 0); struct.pack_into('<I', p, 160, 1)
            p[168:232] = bytes([key]) * 64; p[232:296] = bytes([signature]) * 64
            inputs.append((f'key-signature-{key}-{signature}', file(body(p))))
    p = prefix(); struct.pack_into('<I', p, 120, 3); struct.pack_into('<I', p, 160, 1)
    p[168:232] = bytes(range(1, 65)); p[232:296] = bytes([42]) * 64
    inputs.append(('all-record-types', file(body(p, root=('корень'.encode(), b'root2'),
        mod=(1, 7, [b'own_mod', b'Own mod', b'1', b'', b'']),
        plugins=[plugin(flag=1, digest=bytes([1])*32)], stats=[stat(id=0, name=b'own_stat'), stat(id=32767, flags=1, name=b'last')]))))
    results = []
    for label, data in inputs:
        r.cursor = r.arena
        model, error = r.decode(data)
        if model is None: continue
        canonical, error = r.encode(model)
        assert canonical is not None and error == 0
        digest = r.signing_digest(model)
        payload = bytearray(canonical[44:]); payload[232:296] = bytes(64)
        assert digest == hashlib.sha256(domain + payload).digest()
        # Original signing mode accepts a pending zero signature. Only those
        # 64 bytes are excluded; public key and all remaining fields stay bound.
        r.mu.mem_write(model + 0xdc, bytes(64))
        assert r.signing_digest(model) == digest
        results.append({'label': label, 'fileHex': canonical.hex(), 'digestHex': digest.hex()})
    report = {'referenceSHA256': EXPECTED, 'scope': 'Full original v2 signing digest on own synthetic fixtures; no OS signer, private key or admission.',
              'domainHex': domain.hex(), 'signaturePayloadRange': [232, 296], 'cases': results, 'liveAdmissionVerified': False}
    if args.vectors is None and args.output is None:
        args.vectors = Path(__file__).resolve().parents[1] / 'Tests/ReimaginedClientTests/Fixtures/sidecar-signing-reference.json'
    if args.vectors:
        data = args.vectors.read_bytes()
        if len(data) > 8 * 1024 * 1024 or json.loads(data) != report: raise ValueError('Original signing corpus mismatch')
    if args.output:
        fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'w') as out: json.dump(report, out, indent=2); out.write('\n')
    print('Original sidecar signing digest:', len(results), 'synthetic fixtures; full canonical payload and original SHA256 match.')

if __name__ == '__main__': main()
