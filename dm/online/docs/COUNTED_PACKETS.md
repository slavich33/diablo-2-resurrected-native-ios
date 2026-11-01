# Native counted packet boundaries

The exact stock descriptor table marks the following counted packets as variable. Their
original ARM64 producers and receivers use the following byte counts:

| Opcode | Header bytes | Count offset | Record bytes | Accepted count |
| --- | ---: | ---: | ---: | ---: |
| `0x70` | 6 | 1 | 8 | 0..63 |
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

`0x70` sends at most63 records per510-byte packet. Its final packet is explicit,
including an empty final packet after exact multiples of63. Neither a complete
batch nor the subsequent zero count means end-of-stream. Both packets must reach
the original receiver.

`0x3e` is a different bit-packed format: byte1 stores the total packet size,
including its two-byte header. Its original writer bounds the payload to32
bytes, so the resolver accepts total lengths2..34 and rejects larger or shorter
declarations before native delivery. The contents of that bit payload remain
opaque to the framing layer.

`verify_counted_packet_producer.py` validates the entire owned original NSO
before executing only its bounded producer routines in an offline reference.
Synthetic unit lookup, memory operations and a recording send sink replace
dependencies. All256 payload-count values and all256 source path counts across
four pagination values yield2,304 original-produced packets. Source buffers
remain unchanged. These cases cover empty, partial, saturated and exhausted
path batches. No game entry, OS call, account, server, save or device executes.

With `--extended`, the reference also captures576 bit-packet invocations across
null/8/16/32-bit unit identities and field-width branches, and134 source-record
lists spanning empty, partial, complete and multiple63-record batches. These710
additional invocations produce794 packets. The combined3,098 packets yield27,882
byte-exact comparisons through the nine Swift chunk sizes. The batch reference
verifies that all source records remain unchanged and every record is counted
exactly once, including the empty final packets.

Replay the resulting private synthetic capture through the actual Swift decoder
using `verify_game_packet_capture.swift`. Nine chunk sizes yield20,736 byte-exact
packet comparisons. Swift tests additionally check every split, truncated EOF,
nonzero Data indices, embedded control bytes and terminal refusal of oversized
path counts. This establishes the stock packet boundary, not arbitrary peer
formats, native world admission or saved ladder progress.

```sh
python dm/online/tools/verify_counted_packet_producer.py /path/to/ExeFS/main \
  --extended --scratch /path/to/new-private-scratch

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
capture belongs in Git. Nine other variable formats and full device
gameplay/reconnect/server-save verification remain unfinished.
