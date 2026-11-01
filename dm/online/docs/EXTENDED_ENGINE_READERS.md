# Extended peer readers: experimental integration

The supported stock ARM64 engine and the extended peer use different item and
state layouts. These adapters are explicit build-time options, not a completed
ladder client. They preserve serialized input; unknown formats fail instead of
dropping bytes or scanning for the next apparent opcode.

## Item format 5

`DM_NET_ITEM_FORMAT=1` requires the exact supported main and
`DM_NET_ENGINE_BRIDGE=1`. Two static service gates resume the original header
and body readers after reading the format flags. Flag bit19 announces an
additional 8-bit version marker, which must equal5. The adapters consume that
marker through the original bit-reader state and clear the format flag from
the returned value. They do not remove bytes from packets.

The service requires an activated remote decoder generation and an isolated
server-save namespace. Retail/unbound readers retain their original behavior.
An asynchronous transport failure retains the decoder generation until detach
so an already borrowed packet cannot change format halfway through decoding.

The independent C codec also implements the observed wider identity, magic
affix and rare-name reads, including sentinel/bounds behavior. Those wider
field readers are **not yet connected to all native item call sites**. This is
not full support for every extended inventory item or item format6.

A bounded real-peer native Mac run decoded four simple item payloads through
the original item decoder without its earlier error. This establishes the
prefix correction for those items, not arbitrary equipment, gameplay or iPhone
ladder compatibility.

## Extended state packets

The explicit `ReimaginedServerPacketLengths` profile leaves the stock descriptor
table unchanged and selects these verified peer layouts:

| Opcode | Stock bytes | Extended bytes | Payload |
| --- | ---: | ---: | --- |
| `0x96` | 9 | 11 | stamina32, x16/y16, two8-bit deltas |
| `0x95` | 17 | 23 | life32/mana32/stamina32, coordinates/deltas, frame32 |
| `0x18` | 19 | 25 | medium fields plus two7-bit stats before the coordinates |

`DM_NET_STATE_PACKETS=1` requires the exact supported main and engine bridge.
Three optional receivers use the original unit lookup, resource updates and
position update methods. Medium and big state also preserve conditional revival
and the native mana-prediction ring, including expiry, signed rejection and
32-bit wraparound. Big state retains both additional stats. The peer's delta
boundary is unusual: `0x80` means+128; only `0x81..0xff` are negative.

Each receiver requires an exact borrowed gameplay packet in an activated,
isolated remote scope. Invalid packets or prediction-ring indices fail the
binding. Unbound calls resume their original prologues. A separate static
adapter changes the dispatcher's expected length only in that remote scope;
its actual length comparison remains active. No global stock descriptor is
modified. Changing only the Swift framing or only the final receiver would
leave this earlier native validation incompatible.

A bounded real-peer native Mac run passed the former length assertion and
consumed medium and small state among333 logical packets. The premature
disconnect was subsequently traced to the original backend session monitor;
the scoped coordinator monitor now keeps the real bound connection active.
A later20-second run processed original native HID movement and applied the
new server position to the same native player. Its missing shader cache was
subsequently rebuilt for the exact engine chain. After the additional level
adapters below, a bounded real-peer native Mac run rendered the remote camp,
processed native HID movement and completed without a packet-framing error.
Big state has reference checks but no live observation yet.
Do not expose this profile as a completed Play action in the app.

## Extended levels, objects and portals

`DM_NET_LEVEL_PACKETS=1` additionally requires the supported state/engine
bridge. The peer profile selects these layouts without editing the stock table:

| Opcode | Stock bytes | Extended bytes | Changed fields |
| --- | ---: | ---: | --- |
| `0x07` | 6 | 7 | reveal level16 |
| `0x08` | 6 | 7 | hide level16 |
| `0x51` | 14 | 15 | object interaction16 |
| `0x60` | 12 | 14 | interaction16, destination level16 |
| `0x82` | 80 | 81 | portal level16; following coordinates/state shift |

Changing packet boundaries alone is insufficient: the old native object layout
stores only the interaction's low byte and allocates120 bytes. The scoped
allocator requests128 bytes, records the exact allocation and removes ownership
before the original release. Interaction access uses byte8 and byte0x78 while
preserving flags byte9. Untracked120-byte objects retain their original accesses.
The destination WORD is stored separately at unit+0x1be, preserving state byte1bb.
The map bodies retain their original execution with a scoped full-width read;
object creation uses the original constructor. Warp/link updates preserve the
observed unit-lookup, conditional update and link-call order.

Every field adapter is registered in `dm_net_level_sites.inc`. The rewriter
checks original bytes; the independent structural verifier additionally checks
the original instruction kind, offset, registers and exact single-service cut.
Invalid/unborrowed packets fail the remote binding; unbound entry gates resume
the original prologues. No packet bytes or global offline layout are rewritten.

The bounded Mac run received16,644 bytes, queued2,813 original client bytes and
completed without an unsupported-packet error. A fresh authenticated server
download advanced its version and passed its digest check. Only nine save bytes
changed, so this **does not establish persisted gameplay progress** or a tested
save reload. The physical iPhone game coordinator remains unfinished.

## Verification

```sh
bash dm/online/Tests/NativeTransportABI/items.sh
bash dm/online/Tests/NativeTransportABI/engine.sh
swift test --package-path dm/online --filter ReimaginedServerPacketLengthsTests
make -C dm/host/tests net-levels
python3 -m unittest discover -s dm/verify -p test_net_level_fields.py
```

Development-only bounded comparisons checked1440 item-reader cases and3072
state receiver cases against the owned pinned peer's original code with
synthetic API dependencies. Another2048 cases matched the original ARM64
mana-prediction loop's results and all ring bytes. Generated ARM64 checks cover
192 item cases,96 receiver entry cases and512 dispatcher-length cases,
including bound/unbound flow, registers, stack, flags and cursor preservation.
These references invoke no DLL entry, game entry, OS or network API and are not
a gameplay runtime. An earlier12412-byte peer capture replays with all
boundaries preserved and no leftover bytes under the extended profile.

The changed C sources compile for ARM64 iOS16. Unit checks and private Mac
probes do not establish rendered remote-world play, device input, a server
progress commit, save reload or reconnection on iPhone. Those are still required
before calling ladder support complete. No game data, binaries, captures,
credentials or character files are part of this source change.

Level/portal checks additionally compare1024 receiver cases with full unit/object
memory and dependency-call order, all65536 interaction values, and320 generated
entry-gate cases. C fixtures exercise short packets, neighbor preservation,
old120-byte buffers, allocation capacity and address reuse under ASan/UBSan.
The Swift suite has143 passing tests. These checks do not establish compatibility
with every peer item/variable packet or iPhone ladder gameplay.

The full independent LLVM structure check also passes on the rewritten main,
including both item adapters, all three state gates and the length adapter. It validates the emitted
spill/reload instructions and gate metadata separately from the emitter. Run it
with an installed LLVM toolchain and the owner's original input:

```sh
LLVM_BIN=/path/to/llvm/bin python dm/verify/structck.py /path/to/rewrite main /path/to/ExeFS/main
```
