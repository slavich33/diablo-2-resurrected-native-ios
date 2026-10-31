# Control payload observations

This is a partial interoperability contract independently derived from static inspection and bounded offline encoder checks of the official D2RLoader 1.3.1-beta core, SHA-256 `2a868d013d2e0830bd2d9e04b918b19e46a73cf726c833e70d089b948fdeb5a2`. No original executable code or game assets are included. Two bounded live ladder refusals now verify the early uncompressed control-carrier path below; a live Windows session, successful admission and gameplay interoperability remain unverified.

## Observed live control refusal

On 31 October 2026 a developer-signed native Mac client renewed its authorized PKCE session, fetched fresh policy revision 7, verified the complete signed package (3814 files), obtained a matching native launch ticket/narrow token and resolved one public room. After the server's exact `af00` greeting, it sent one 39-byte kind 7 carrier containing an empty D2EM-v3 envelope, without character bytes, credentials, gameplay commands or claimed compatibility fingerprints. The server returned one 25-byte D0/D2RL carrier, kind 9, payload `01 00 00 00`. Both length fields and all envelope fields match the native decoder; the connection was closed and token-revocation request accepted. No save write was attempted.

This verifies an early bidirectional control exchange and an explicit refusal, not successful environment validation or game admission. It does not establish all gameplay/system wire formats, compression behavior or reconnect/save handling. The response is recorded without endpoint, identity or secrets in `Fixtures/live-incomplete-environment-rejection.json`; it replays through every split boundary with distinct system/control routing.

`AdmissionRejection` separately decodes kind 9 payloads as a code 1..30, three byte lengths 0..63 and the three exact byte fields. Those bounds come from the pinned core's rejection encoder/readers; code1 with empty fields and code22 with fields empty/ASCII1/ASCII0 are live-verified here. The pinned original comparison maps code22 to the sidecar-capability word, matching the live server1/client0 result. Other field semantics and reason names remain unassigned. Generic `ControlMessage` remains a framing codec; parsing kind 8 alone still does not establish admission.

A second bounded check used the same verified revision7 package and native identity, and sent the actual 166-byte `EnvironmentDescription.unavailableProfile()` through kind7 (195 carrier bytes). Before sending, its exact output independently matched a manual encoding and passed the complete pinned original D2EM parser/local validator. This description declares no known data fingerprints, no plugins and no sidecar support; it copies no host fingerprints. The server returned29 total bytes, including its greeting and a kind9 refusal with code22 and three fields empty/ASCII1/ASCII0. Static original comparison branches identify this as a sidecar-capability mismatch. No host profile, character, gameplay command or save write was exchanged. The connection closed and narrow-token revocation request was accepted. The identity-free response is `Fixtures/live-unavailable-environment-rejection.json`.

The native required-field representation and its original-parser reference procedure are documented in [ENVIRONMENT_DESCRIPTION.md](ENVIRONMENT_DESCRIPTION.md). A syntactically valid manifest is not a compatible gameplay environment; the missing sidecar behavior must be implemented before it can truthfully be advertised.

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

`GamePacketStream` assembles this carrier across partial reads and can interleave it with ordinary game packets **after transport processing**. Its packet-length resolver must be independently verified. The original callback tests use synthetic stock packets; `StockServerPacketLengths` additionally supplies the 126 fixed packet lengths from the supported ARM64 engine. All 175 descriptors (including 23 variable and 26 invalid entries) independently match the pinned Windows reference. Eight variable formats now have separate native-reader and original-engine capture evidence below; 15 remain unsupported. No packet is sized from a TCP read or copied from a legacy game's table. System-channel opcodes beginning at `0xaf` are outside this table. This decoder is not yet attached to the game's packet pump or directly to raw production TCP.

`dm_online_packets_open_stock_94012()` exposes the supported fixed and variable sizes without calling guest code. It preserves D2RL routing, bounded buffering, short-output retry and terminal errors. It refuses an unimplemented variable/invalid/system opcode before any later carrier can be interpreted. Malformed declared lengths are terminal `invalidLength`, separately from an unsupported opcode. Generic C callbacks return -2 for an invalid length, -1 for unsupported, 0 for more header and positive lengths for complete sizing. To recheck the protocol metadata against owned inputs without executing any game function:

```sh
python dm/online/tools/verify_stock_lengths.py /path/to/original/ExeFS/main \
  --windows-reference /path/to/pinned-3.3.93847/D2R.exe
```

The Windows argument is optional and accepts only the independently pinned image hash. The tool pins the complete ARM64 input, compares every Swift descriptor, and rejects mismatches. This proves fixed-length metadata, not variable formats, system routing, transport framing/compression or admission. Tests cover real fixed lengths at every split boundary (including 511/512-byte packets with embedded loader magic), mixed stock/control order, truncated EOF and unsupported packets; the independent C harness also checks the new entry point and retained short-buffer retry.

### Supported native variable formats

These rules refer to complete logical game packets, not socket records. Offsets are zero-based; `u16-le(1)` includes the opcode in its total. Minimums reject a size shorter than the native reader's required header. This is framing validation, not full gameplay-body validation.

| Opcode | Total bytes | Required header / accepted bounds |
| --- | --- | --- |
| `0x5b` | `u16-le(1)` | total >= 96; fixed reader reaches byte 94, terminated tail starts at 95 |
| `0x67` | `22 + 4 * byte(20)` | need 21 bytes to determine size |
| `0x94` | `6 + 3 * byte(1)` | need 2 bytes to determine size |
| `0x9c` | `byte(2)` | 8..252, matching the native copy guard |
| `0x9d` | `byte(2)` | 13..255 |
| `0xa8` | `byte(2)` | 9..255; native state-add differs from legacy byte6 |
| `0xaa` | `byte(6)` | 9..255 |
| `0xac` | `byte(12)` | 13..255 |

The original native reader for `0x67` copies `4*byte(20)` bytes starting at 22; `0x94` iterates three-byte entries after its six-byte header. The state readers calculate bit budgets from the indicated byte length after their nine/thirteen-byte headers. These reader observations were checked against actual original-engine complete-packet boundaries: an isolated offline capture of 246 packets, a separate 233-packet holdout collected after implementing the rules, then 353 packets from scripted movement/actions. All 832 packets (including all eight variable forms) replayed exactly through chunks of 1, 2, 3, 7, 31, 127, 512, 4096 and 65536 bytes, for 7488 byte-exact packet comparisons. The action run produced no additional unimplemented variable format. A changed declared boundary was independently rejected. This is native-format evidence; it does not prove Windows variable-format equivalence, live ladder transport or admission. Missing Mac graphics libraries in these diagnostic runs also prevent using them as rendering/FPS evidence.

`tools/verify_game_packet_capture.swift` consumes a trusted private JSONL capture with `sequence`, `direction`=`s2c-game`, `id`, `length` and hex `payload`. It validates reference records before independently concatenating, chunking, decoding and comparing every packet byte/boundary. It caps input at 32 MiB / 10000 records / 8 MiB decoded bytes and never prints payloads. An arbitrary JSON file does not prove original-engine provenance. Do not publish captures, character data or game resources. Build and run the verifier on owned private observations:

```sh
xcrun --sdk macosx swiftc -parse-as-library -O -module-name StockCaptureCheck \
  dm/online/Sources/ReimaginedClient/{ControlMessage,LoaderFrame,NativeSystemPacket,GamePacketStream,StockServerPacketLengths}.swift \
  dm/online/tools/verify_game_packet_capture.swift -o /private/scratch/verify-capture
/private/scratch/verify-capture /private/captures/original-engine.jsonl
```

### Native logical system channel

`NativeSystemPacket` implements the four native formats below. This is the exact ARM64 engine's logical system boundary, separately from gameplay and D2RL. It does not establish the Windows peer's system format, raw TCP lengths, compression mode or admission. In particular, do not feed raw TCP directly into this decoder.

| Opcode | Total bytes | Preserved body |
| --- | --- | --- |
| `0xaf` | 2 | one auxiliary byte; the native consumer sets its ready flag |
| `0xb0` | 1 | no body; the native consumer clears its ready flag |
| `0xb3` | `3 + byte(1)` | marker at2, then0..255 character-data bytes |
| `0xb4` | 5 | u32-le reason at1; the original consumer maps it to its UI error |

The original AF producer stores `0x00af` and sends a two-byte span. The B0 producer sends a one-byte span. The original system dispatcher reads B3's length/marker at1/2 and payload at3, and reads B4's reason at1. B1/B2 are ignored by that dispatcher; their complete production lengths were not independently derived, so this codec refuses them rather than guessing.

The exact original ARM64 B3 producer at `main+0x5d6b80` sends at most255 data bytes per chunk with a three-byte header, marks the first chunk of each segment with1 and later chunks with0, then emits `b3 00 00`. The independent bounded reference executes that original function on synthetic bytes, replacing only generic copy/fill, the outgoing queue boundary and the final resource-release helper. It exercises1034 cases: all lengths0..1025, larger boundaries through65536, multiple segments, empty vectors and disabled sends. It invokes no OS, network or game entry point and does not read/write character saves.

```sh
python dm/online/tools/verify_native_system_packets.py /path/to/original/ExeFS/main \
  --output /private/scratch/system-reference.jsonl
/private/scratch/verify-capture --native-system /private/scratch/system-reference.jsonl
```

The output file must not already exist. `--native-system` additionally verifies system/game direction at every returned packet, through the same nine chunk sizes. Generic/stock decoder entry points retain their old behavior; only explicit native opt-in emits `.system` / C kind4. A character transfer terminator is not a durable server-save receipt or an accepted gameplay-progress upload. No automatic save mounting, game admission or packet-pump activation is added.

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

`Fixtures/loader-frames-reference.json` retains 30 synthetic reference cases, including rejected inputs; the Swift suite checks them and stream/assembly failure cases. The independent C test additionally covers opaque fragment routing and the 65538-byte carrier through split input and output-buffer retry. At that codec checkpoint the Swift suite had 51 passing tests; current totals are recorded in the module README. Repeat the published oracle cases with:

```sh
python tools/verify_loader_frames.py --dll /path/to/your/D2RCore.dll
```

The matching result proves these codecs against the pinned reference components. It does not prove original packet-size callbacks, TCP framing/compression, complete D2RL admission, required native plugin behavior, remote role bootstrap, accepted ladder join or server-save persistence.
