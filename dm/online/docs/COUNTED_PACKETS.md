# Native counted packet boundaries

The exact stock descriptor table marks these three packets as variable. Their
original ARM64 producers and receivers use the following byte counts:

| Opcode | Header bytes | Count offset | Record bytes | Accepted count |
| --- | ---: | ---: | ---: | ---: |
| `0x71` | 23 | 21 | 4 | 0..15 |
| `0x72` | 22 | 20 | 4 | 0..15 |
| `0x78` | 7 | 6 | 1 | 0..255 |

The complete length is `header + count * record`. For path batches, the last
two header bytes hold the count and pagination metadata. They precede the
records; omitting them would split a packet inside its original header. The
producer limits each path batch to15 records. The receiver copies those records
into a fixed local buffer, so the resolver rejects higher counts before delivery.
The `0x78` count excludes its seven-byte header and permits a262-byte packet.
Payloads remain opaque, including bytes resembling subsequent opcodes/carriers.

`verify_counted_packet_producer.py` validates the entire owned original NSO
before executing only its bounded producer routines in an offline reference.
Synthetic unit lookup, memory operations and a recording send sink replace
dependencies. All256 payload-count values and all256 source path counts across
four pagination values yield2,304 original-produced packets. Source buffers
remain unchanged. These cases cover empty, partial, saturated and exhausted
path batches. No game entry, OS call, account, server, save or device executes.

Replay the resulting private synthetic capture through the actual Swift decoder
using `verify_game_packet_capture.swift`. Nine chunk sizes yield20,736 byte-exact
packet comparisons. Swift tests additionally check every split, truncated EOF,
nonzero Data indices, embedded control bytes and terminal refusal of oversized
path counts. This establishes the stock packet boundary, not arbitrary peer
formats, native world admission or saved ladder progress.

```sh
python dm/online/tools/verify_counted_packet_producer.py /path/to/ExeFS/main \
  --scratch /path/to/new-private-scratch

swiftc dm/online/Sources/ReimaginedClient/ControlMessage.swift \
  dm/online/Sources/ReimaginedClient/LoaderFrame.swift \
  dm/online/Sources/ReimaginedClient/NativeSystemPacket.swift \
  dm/online/Sources/ReimaginedClient/GamePacketStream.swift \
  dm/online/Sources/ReimaginedClient/StockServerPacketLengths.swift \
  dm/online/tools/verify_game_packet_capture.swift -o /path/to/private-replay

/path/to/private-replay /path/to/new-private-scratch/counted-producers.private.jsonl
swift test --package-path dm/online
```

The Python reference requires the same local `unicorn`/`lz4` development
dependencies as the other owned-input verifiers. No original image or generated
capture belongs in Git. Eleven other variable formats and full device
gameplay/reconnect/server-save verification remain unfinished.
