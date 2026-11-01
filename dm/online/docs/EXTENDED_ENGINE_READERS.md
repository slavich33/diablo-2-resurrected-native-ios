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

## Small state packet

The explicit `ReimaginedServerPacketLengths` profile keeps the stock descriptor
table unchanged. Its `0x96` has11 bytes: opcode, a 32-bit resource, two16-bit
coordinates and two8-bit destination deltas. The stock packet has9 bytes.
Treating the extended packet as stock can turn its trailing deltas into false
packet identifiers.

`DM_NET_STATE_PACKETS=1` requires the exact main and engine bridge. Its optional
`0x96` receiver uses the original engine's unit lookup, stamina update and
position update methods. It accepts only an exact11-byte borrowed gameplay
packet in the activated isolated remote scope. An invalid packet fails the
binding. Unbound calls resume the original receiver. The peer's unusual delta
boundary is preserved: `0x80` means+128; only `0x81..0xff` are negative.

The medium (`0x95`) and large (`0x18`) peer readers are also extended. Their
native adapters remain unfinished; the explicit profile rejects them before
using a shorter stock length. A subsequent real-peer run stopped cleanly at
`0x95`, so the new small-state adapter has not yet been exercised on a complete
live stream. Do not enable this profile as a Play action in the app yet.

## Verification

```sh
bash dm/online/Tests/NativeTransportABI/items.sh
bash dm/online/Tests/NativeTransportABI/engine.sh
swift test --package-path dm/online --filter ReimaginedServerPacketLengthsTests
```

Development-only bounded comparisons checked1440 item-reader cases and1024
small-state cases against the owned pinned peer's original leaf/receiver code
with synthetic API dependencies. Generated ARM64 adapter checks covered192
item cases and32 small-state gate cases, including bound/unbound control flow,
registers, stack and cursor preservation. These references invoke no DLL entry,
game entry, OS or network API and are not a gameplay runtime.

The changed C sources compile for ARM64 iOS16. Unit checks and private Mac
probes do not establish rendered remote-world play, device input, a server
progress commit, save reload or reconnection on iPhone. Those are still required
before calling ladder support complete. No game data, binaries, captures,
credentials or character files are part of this source change.

The full independent LLVM structure check also passes on the rewritten main,
including both item adapters and the small-state gate. It validates the emitted
spill/reload instructions and gate metadata separately from the emitter. Run it
with an installed LLVM toolchain and the owner's original input:

```sh
LLVM_BIN=/path/to/llvm/bin python dm/verify/structck.py /path/to/rewrite main /path/to/ExeFS/main
```
