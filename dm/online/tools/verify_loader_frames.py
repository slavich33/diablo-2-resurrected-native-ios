"""Offline frame/oversized-command reference. No OS, game or server runs.

Unicorn is used only as a bounded desktop development oracle. The iOS product
uses the independently implemented Swift codec, never an x86 CPU model or DLL.
"""
from pathlib import Path
import argparse
import json
import struct
from unicorn.x86_const import UC_X86_REG_RCX, UC_X86_REG_RDX, UC_X86_REG_R8
from verify_reference_vectors import Reference, EXPECTED


class FrameReference(Reference):
    def __init__(self, dll):
        super().__init__(dll)
        self.captured = []

    def hook(self, mu, pc, size, user):
        try:
            rva = pc - self.base
            # A single-threaded encoder oracle has no shared queue contention.
            # Locks and vector free are stand-ins; no platform APIs are exposed.
            if rva in (0x5398a0, 0x5398c0, 0x513710):
                self.ret(0)
                return
            if rva == 0x53a4e0:  # generic memory copy, bounded private arena
                dst, src, count = map(mu.reg_read, (UC_X86_REG_RCX, UC_X86_REG_RDX, UC_X86_REG_R8))
                if count > 65_536:
                    raise ValueError("Reference copy limit")
                if count:
                    mu.mem_write(dst, bytes(mu.mem_read(src, count)))
                self.ret(dst)
                return
            if rva == 0x453050:  # client queue: tag2 + game carrier
                begin = mu.reg_read(UC_X86_REG_RCX)
                if bytes(mu.mem_read(begin, 2)) != b"\x02\xd0":
                    raise ValueError("Unexpected reference queue tag")
                count = 3 + int.from_bytes(mu.mem_read(begin + 2, 2), "little")
                if not 21 <= count <= 213:
                    raise ValueError("Reference fragment carrier limit")
                self.captured.append(bytes(mu.mem_read(begin + 1, count)))
                self.ret(1)
                return
            super().hook(mu, pc, size, user)
        except Exception as error:
            self.problem = str(error)
            mu.emu_stop()

    def frame(self, kind, channel, message, sequence, payload):
        if len(payload) > 65_535:
            raise ValueError("Reference payload limit")
        self.cursor = self.arena
        out, span = self.vector(), self.span(payload)
        self.run(0x4a9a90, [out, kind, channel, message], [sequence, span])
        return self.readvec(out)

    def decode(self, data):
        if len(data) > 65_553:
            raise ValueError("Reference envelope limit")
        self.cursor = self.arena
        span, out = self.span(data), self.alloc(32)
        accepted = self.run(0x4517a0, [span, out]) & 255
        if not accepted:
            return None
        fields = bytes(self.mu.mem_read(out, 32))
        begin, count = struct.unpack_from("<QQ", fields, 16)
        if count > 65_535:
            raise ValueError("Reference decoded length limit")
        return (fields[0], struct.unpack_from("<H", fields, 2)[0],
                struct.unpack_from("<H", fields, 4)[0], struct.unpack_from("<I", fields, 8)[0],
                bytes(self.mu.mem_read(begin, count)) if count else b"")

    def large(self, packet, sequence):
        if len(packet) > 65_536 or not 1 <= sequence <= 0xffffffff:
            raise ValueError("Reference packet/sequence limit")
        self.cursor, self.captured = self.arena, []
        # Real sender increments this counter once per whole command. The test
        # supplies a valid nonzero current sequence, not an account/session ID.
        self.mu.mem_write(self.base + 0x711d90, struct.pack("<I", sequence))
        accepted = bool(self.run(0x44b820, [self.span(packet)]) & 255)
        return accepted, self.captured


def verify(dll, corpus):
    if corpus["referenceSHA256"] != EXPECTED:
        raise ValueError("Unsupported reference corpus")
    reference = FrameReference(dll)
    for case in corpus["frames"]:
        data = bytes.fromhex(case["frameHex"])
        decoded = reference.decode(data)
        if bool(decoded) != case["accepted"]:
            raise ValueError("Frame acceptance mismatch")
        if decoded:
            kind, channel, message, sequence, payload = decoded
            if (kind, channel, message, sequence, payload.hex()) != (
                    case["kind"], case["channel"], case["message"], case["sequence"], case["payloadHex"]):
                raise ValueError("Frame fields mismatch")
            if reference.frame(kind, channel, message, sequence, payload) != data:
                raise ValueError("Frame encoder mismatch")
    for case in corpus["largePackets"]:
        accepted, carriers = reference.large(bytes.fromhex(case["packetHex"]), case["sequence"])
        if accepted != case["accepted"] or [data.hex() for data in carriers] != case["carrierHex"]:
            raise ValueError("Oversized command sender mismatch")
    return len(corpus["frames"]), len(corpus["largePackets"])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dll", required=True, help="Local official core; never uploaded")
    parser.add_argument("--vectors", type=Path, default=Path(__file__).resolve().parents[1] /
                        "Tests/ReimaginedClientTests/Fixtures/loader-frames-reference.json")
    args = parser.parse_args()
    frames, packets = verify(args.dll, json.loads(args.vectors.read_text()))
    print(f"PASS: {frames} frame and {packets} oversized-command cases; live interoperability unverified")
