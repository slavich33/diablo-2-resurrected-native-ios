# Control payload observations

This is a partial interoperability contract independently derived from static inspection and bounded offline encoder checks of the official D2RLoader 1.3.1-beta core, SHA-256 `2a868d013d2e0830bd2d9e04b918b19e46a73cf726c833e70d089b948fdeb5a2`. No original executable code or game assets are included. It has not been validated against a live Windows game session or ladder server.

## Shared envelope and opaque messages

`LoaderFrame` implements the shared envelope for kinds 1..11. Its fixed header is magic `D2RL`, version 1, kind:u8, reserved:u16=0, channel:u16, message:u16, sequence:u32 and payloadLength:u16, all multibyte fields little-endian. Only the reserved field must be zero at this generic layer. The inspected leaf decoder accepts up to 65535 payload bytes for kinds 1..3, and up to 224 for kinds 4..11. Kind-specific semantics still need separate validation; an accepted envelope is not an accepted plugin channel or game session.

The game carrier counts the **entire envelope** in u16. Therefore its maximum payload is 65517, maximum body 65535 and maximum carrier 65538 bytes including the three-byte carrier prefix. Standalone envelopes with larger kind 1..3 payloads can be decoded but cannot be encoded into that carrier; the encoder throws rather than wrapping the length. TCP writes/reads must still be chunked according to their transport limits.

`GamePacketStream` preserves kinds 1..6 and 11 as opaque `.loader` messages, while kinds 7..10 retain the stricter existing `ControlMessage` checks below. The C polling bridge returns kind 3 for opaque carriers, kind 2 for existing control messages and kind 1 for ordinary gameplay. **Kind 3 must never be routed straight into a gameplay queue.** This adds framing support, not the missing handshake/channel state machines. Contradictory fixed headers are rejected before buffering a claimed large payload.

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

## Bidirectional control carrier at the game-packet layer

The carrier is `0xd0`, a two-byte little-endian D2RL-payload length, then that payload. Its length excludes the three carrier-header bytes. `ControlMessage.gameCarrier()` produces this game message, at most 245 bytes. The old `clientCarrier()` name remains an alias.

On 31 October 2026, the client and server control-send builders were additionally checked at their respective queue boundaries. Both produce the same carrier. The server builder preserves the supplied client ID at its queue boundary. The offline harness intercepts these queues to collect bytes; it does not test a real queue, socket, transport encoding or remote server.

This does not specify transport-level framing/compression, ordinary gameplay packet lengths, authenticated admission, or Server Saves. Do not treat an arbitrary TCP read as one carrier, and do not infer a successful game connection from a decoded control message.

## Incremental decoding and the native polling boundary

`GamePacketStream` assembles this carrier across partial reads and can interleave it with ordinary game packets **after transport processing**. Its packet-length resolver must be independently verified. The original callback tests use synthetic stock packets; `StockServerPacketLengths` additionally supplies the 126 fixed packet lengths from the supported ARM64 engine. All 175 descriptors (including 23 variable and 26 invalid entries) independently match the pinned Windows reference. The variable entries remain unsupported; they are not sized from a TCP read or a legacy game's table. System-channel opcodes beginning at `0xaf` are outside this table. This decoder is not yet attached to the game's packet pump or directly to raw production TCP.

`dm_online_packets_open_stock_94012()` exposes those fixed sizes without calling guest code. It preserves existing D2RL routing, bounded buffering, short-output retry and terminal errors. It refuses a variable/invalid/system packet before any later carrier can be interpreted; the generic callback entry point remains available for a future complete verified resolver. To recheck the protocol metadata against owned inputs without executing any game function:

```sh
python dm/online/tools/verify_stock_lengths.py /path/to/original/ExeFS/main \
  --windows-reference /path/to/pinned-3.3.93847/D2R.exe
```

The Windows argument is optional and accepts only the independently pinned image hash. The tool pins the complete ARM64 input, compares every Swift descriptor, and rejects mismatches. This proves fixed-length metadata, not variable formats, system routing, transport framing/compression or admission. Tests cover real fixed lengths at every split boundary (including 511/512-byte packets with embedded loader magic), mixed stock/control order, truncated EOF and unsupported packets; the independent C harness also checks the new entry point and retained short-buffer retry.

The decoder preserves order, accepts coalesced reads, caps input storage at 256 KiB and individual packets at 64 KiB, and exposes one packet per poll. A full input buffer rejects the entire append for retry after draining. Unknown packet IDs, invalid lengths and truncated EOF terminate that decoder; it never scans gameplay bytes for the next `D2RL` magic. These caps are local memory policies.

The 64 KiB individual limit applies to stock gameplay packets. Opaque carriers use their separately checked 65538-byte maximum; a short C output buffer retains one for retry. Receiving a whole fragment carrier is not the same as receiving a whole fragmented game command.

The C functions in `OnlineTransport.h` expose append/end/read operations and a synchronous length callback. All scalar ABI arguments are at least 32 bits for Apple/Horizon compatibility. The caller serializes operations and keeps the resolver context alive. Output kind 1 is ordinary gameplay; kind 2 is a complete D2RL control 7..10 carrier; kind 3 is another opaque D2RL carrier. A short output buffer retains the packet for a larger-buffer retry. Reading or parsing a loader message never sets an admitted state. The engine's roles, length resolver and delivery callbacks remain to be bound and verified.

## Oversized client-to-host commands

The pinned core's client command sender has a kind 11 fragmentation path. The inspected receiver is host-side; this is not evidence that servers send the same fragments to clients. A kind 11 envelope uses zero channel/message, a nonzero whole-command sequence and payload `total:u16,offset:u16,chunk:1..188 bytes`. Total is 513..1817. The sender emits consecutive 188-byte chunks; the final one may be shorter. The native codec checks exactly the four observed variable command forms:

| Opcode | Fixed header bytes | Bytes per entry | Entry count |
| --- | --- | --- | --- |
| `0x20` | 8 | 5 | final header byte +1 |
| `0x22` | 10 | 7 | final header byte +1 |
| `0x4e` | 7 | 5 | final header byte +1 |
| `0x60` | 25 | 7 | final header byte +1 |

Length must equal header plus count times entry width. This is not a general stock packet-size table. `LargeGamePacketFragment.split` is for this specific outbound command path; unsupported input must not be relabeled as an accepted wide command.

`LargeGamePacketAssembly` maintains one ordered transfer per peer/connection. Offset zero starts or replaces it; subsequent fragments must match sequence, total and the next byte offset. A mismatch clears the transfer. Completion validates the command shape before returning it. Call `endOfInput` as well as ending the frame stream: EOF between whole fragment carriers otherwise looks like a clean frame-stream EOF. Reset on timeout, rejection and disconnect. Matching wide engine command handlers and their admission/role policy remain necessary before delivery; no engine callback is invoked by this assembler.

## Verification

The official core's three encoder functions were additionally evaluated on a Mac in an offline Unicorn CPU model: 276 control cases (including all 256 kind values), 216 fragment boundary cases and 12 carrier cases. All 504 results matched the independently implemented layout and acceptance rules. Generic C++ vector allocation/append helpers are substituted with bounded local memory operations; no DLL entry point, Windows OS API, game process or server is involved. This checks encoder behavior only.

45 selected official outputs and rejection cases are retained in `Tests/ReimaginedClientTests/Fixtures/loader-control-reference.json`. A second corpus, `loader-control-senders.json`, adds 72 client/server send-builder cases, including invalid kinds and boundary sizes, captured at intercepted queue boundaries. All 117 fixtures are checked by the Swift suite. The 504 original encoder cases plus the 72 send-builder cases matched. Both corpora record the pinned source-core hash and explicitly mark live interoperability unverified. Original executable bytes are not distributed.

To repeat the first corpus, install `unicorn==2.1.4` in a separate Python virtual environment and run `python tools/verify_reference_vectors.py --dll /path/to/your/D2RCore.dll` from `dm/online`. Add `--vectors Tests/ReimaginedClientTests/Fixtures/loader-control-senders.json` for the 72 sender cases. The harness rejects other core hashes and uses instruction, memory and copy limits. It exposes no OS imports. This is development tooling; the iOS client remains native Swift/C/ARM64.

Malformed-length cases and a full 65536-byte fragment/assembly check are also covered by Swift tests. A real loopback TCP peer independently checks the client control vector while exercising bounded buffering and EOF. The separate C/POSIX check verifies the engine-facing C ABI. These checks establish component behavior, not game interoperability.

The additional shared-envelope decoder and oversized client-command sender were evaluated offline in the same bounded reference model: 1030 frame cases (all 256 kind values and payload boundaries) and 1024 command cases (all 256 entry-count values for each of the four forms). The independently compiled native Swift codec matched all 2054 cases, including acceptance/rejection and actual sender-queue bytes. These checks substitute only generic allocation/copy/free, uncontended locks and the observed queue boundary; they do not execute a DLL entry point, Windows API, game process or remote server. The native sender sequence is supplied as a valid nonzero counter value, as required by the receiver.

`Fixtures/loader-frames-reference.json` retains 30 synthetic reference cases, including rejected inputs; the Swift suite checks them and stream/assembly failure cases. The independent C test additionally covers opaque fragment routing and the 65538-byte carrier through split input and output-buffer retry. The full Swift suite now has 51 passing tests. Repeat the published oracle cases with:

```sh
python tools/verify_loader_frames.py --dll /path/to/your/D2RCore.dll
```

The matching result proves these codecs against the pinned reference components. It does not prove original packet-size callbacks, TCP framing/compression, complete D2RL admission, required native plugin behavior, remote role bootstrap, accepted ladder join or server-save persistence.
