# Control payload observations

This is a partial interoperability contract independently derived from static inspection of the official D2RLoader 1.3.1-beta core, SHA-256 `2a868d013d2e0830bd2d9e04b918b19e46a73cf726c833e70d089b948fdeb5a2`. No original executable code or game assets are included. It has not been validated against a live Windows game session or ladder server.

## D2RL version 1 control payload

| Offset | Bytes | Encoding |
| --- | --- | --- |
| 0 | 4 | ASCII `D2RL` |
| 4 | 1 | Version `1` |
| 5 | 1 | Control kind `7` through `10` |
| 6 | 2 | Zero in control messages |
| 8 | 2 | Zero in control messages |
| 10 | 2 | Zero in control messages |
| 12 | 4 | Zero in control messages |
| 16 | 2 | Little-endian payload byte count |
| 18 | 0..224 | Payload |

The inspected control builder sets offsets 6..15 to zero. Their meaning in other message families is outside this codec. Kind 7 carries environment-manifest fragments in the inspected send path. Kinds 8..10 are bounded and preserved without assigning unverified admission semantics.

## Environment fragments

The kind-7 payload is `total:u32-le`, `offset:u32-le`, followed by 1..216 bytes. Total is at most 65536; a fragment cannot extend beyond it. The inspected sender emits increasing offsets in chunks of at most 216 bytes.

The Swift ordered assembler is a conservative local policy for one peer/connection. Rejecting overlaps or changed totals does not reproduce the loader's whole receive state machine. Reset on timeout, rejection, disconnect or a new peer. A fully assembled manifest still requires D2EM field/compatibility validation; receiving one never grants admission.

## Client-to-server carrier

The inspected client carrier is `0xd0`, a two-byte little-endian D2RL-payload length, then that payload. Its length excludes the three carrier-header bytes. `ControlMessage.clientCarrier()` produces this game message, at most 245 bytes.

This does not specify the server-to-client carrier, the full mixed game stream, transport-level processing/compression, ordinary gameplay packets, authenticated admission, or Server Saves. Do not treat an arbitrary TCP read as one carrier, and do not infer a successful game connection from a decoded control message.

## Verification

Fixed little-endian vectors, malformed-length cases and a full 65536-byte fragment/assembly check are covered by Swift tests. A real loopback TCP peer independently checks the client control vector while exercising bounded buffering and EOF. The separate C/POSIX check verifies the engine-facing C ABI. These checks establish component behavior, not game interoperability.
