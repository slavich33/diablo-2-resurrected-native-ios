# ARM64 packet queues and remote binding

The optional build-time `DM_NET_ENGINE_BRIDGE=1` cuts instrument the three client queue methods in Switch build 3.3.94012. Without an explicit remote binding they resume the original methods. No TCP connection or admission is created at app startup.

| Method entry in main | Client vtable slot | Inputs |
| --- | --- | --- |
| `0x8401c0` | `0x00`, system receive | x0: client; x1: **u64 queue cursor**; x8: optional-span output |
| `0x840290` | `0x08`, gameplay receive | Same receive ABI, separate queue |
| `0x840354` | `0x30`, send | x0: client; x1: begin/end byte span |

The receive output is a 24-byte `{begin:u64,end:u64,present:u8,padding}`. The cursor advances over internal length-prefixed records; it is not an error output. Internal queue records do not establish the TCP framing contract.

The first implementation instrumented individual calls at `0x2cec94` and `0x2cfa5c`. That receive call only covered a system-channel caller, so it missed the main gameplay queue. New builds cut the methods themselves. The old SVC handlers remain for previously built diagnostic modules.

Each method's first two instructions are replaced offline by `svc; ret`. `net_engine_entry.S` reconstructs exactly their original stack prologue and branches into the signed rewritten body at entry+8. This preserves the Horizon hidden x8 result argument without generating executable code or changing guest vtables at runtime. Gate dispatch validates the original module-relative site and identifies its mapped module from the gate return PC.

`tools/check_engine_input.py` verifies the original module ID, all three NSO segment hashes, the queue-method windows and prior call-site anchors. The rewriter also checks every replaced byte. Use the owner's original modules:

```sh
python dm/online/tools/check_engine_input.py /path/to/ExeFS/main
DM_NET_ENGINE_BRIDGE=1 DM_RULESET=touch-run-v4 \
  python dm/tools/patch_nso.py /path/to/ExeFS/main /path/to/output main
dm/online/Tests/NativeTransportABI/engine.sh
```

Build the SDK and required modules with matching source/tool versions. An iPhone app must embed the new rewritten main; the flag is not a runtime switch.

## Remote packet boundary

`dm_net_binding.h` connects a specifically registered client object to native inbound/outbound queues. Its API is available to the iOS shell through `OnlineBridge.h`. Attach and detach only with the engine quiescent and the remote role, rewritten gates, transport and save scope prepared. The account screen does not yet activate this binding.

The network side drains outgoing **complete game packets** with `dm_net_remote_read`, and feeds incoming complete packets into system or gameplay channels with `dm_net_remote_feed`. A verified transport codec must perform framing/decompression and channel classification first. Raw TCP reads must not be fed directly. D2RL admission/control handling remains above these queues; feeding a packet does not mark a player admitted.

Each queue is capped at 256 KiB/1024 packets, with 64 KiB per packet. A short outgoing buffer retains the packet for retry. Overflow is terminal and observable through `dm_net_remote_error`; it does not silently drop commands and continue. Closed bindings remain attached until explicit detach, so an interrupted remote game cannot fall back to local queues. Generation IDs reject late network callbacks from a previous connection.

There is one engine consumer per receive channel. Received spans stay valid until that channel's next poll. Asynchronous close retains the current span; detach requires quiescent consumers. Input is copied before a producer returns.

## Checks and limits

The independent ARM64 assembly test covers original prologue continuation, arguments, hidden output, padding canaries, remote routing, retry retention, span lifetime across close, stale generations and overflow. The check also passed AddressSanitizer/UndefinedBehaviorSanitizer.

A bounded isolated native Mac run reached the offline world and traced 327 actual queue packets: 96 outgoing, 230 incoming gameplay and one incoming system packet, across 62 opcode/length combinations. This verifies the default forwarding path in the actual engine, not an actual remote/ladder game. The remote binding path currently has component-test evidence only.

`DM_NET_ENGINE_TRACE=/path/to/private.jsonl` records opcode, length, direction and sequence without payload, character or account identity. Use a fresh private path for a bounded run.

Remote role bootstrap, verified stock packet sizing, TCP framing/compression, environment/admission semantics and a real server-character save/readback still require implementation and end-to-end verification.
