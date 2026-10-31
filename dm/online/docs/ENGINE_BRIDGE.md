# ARM64 client lifecycle, packet queues and remote binding

The optional build-time `DM_NET_ENGINE_BRIDGE=1` cuts instrument the client queue and lifecycle methods in Switch build 3.3.94012. Without an explicit remote binding they resume the original methods. No TCP connection or admission is created at app startup.

| Method entry in main | Client vtable slot | Inputs |
| --- | --- | --- |
| `0x8401c0` | `0x00`, system receive | x0: client; x1: **u64 queue cursor**; x8: optional-span output |
| `0x840290` | `0x08`, gameplay receive | Same receive ABI, separate queue |
| `0x840354` | `0x30`, send | x0: client; x1: begin/end byte span |
| `0x841670` | `0x38`, connected | x0: client; bool result in w0 |
| `0x841720` | `0x40`, failed | x0: client; bool result in w0 |
| `0x83fe64` | `0x10`, hard close | x0: client |
| `0x83fe9c` | `0x18`, graceful close | x0: client |
| `0x8404d4` | `0x20`, connect | x0..x7 and a ninth argument on the caller's stack |
| `0x841568` | `0x28`, start | x0: client; x1: string reference; w2: port |
| `0x841740` | `0x48`, can connect | x0: client; bool result in w0 |

The receive output is a 24-byte `{begin:u64,end:u64,present:u8,padding}`. The cursor advances over internal length-prefixed records; it is not an error output. Internal queue records do not establish the TCP framing contract.

The first implementation instrumented individual calls at `0x2cec94` and `0x2cfa5c`. That receive call only covered a system-channel caller, so it missed the main gameplay queue. New builds cut the methods themselves. The old SVC handlers remain for previously built diagnostic modules.

Queue, status and close methods have their first two instructions replaced offline by `svc; ret`. `entry.S` reconstructs exactly their displaced instructions and branches into the signed rewritten body at entry+8. The failed-status leaf contains a conditional branch in those instructions: its native continuation explicitly preserves both original destinations. The hard-close continuation preserves the comparison flags consumed by the next original instruction. This preserves the Horizon hidden x8 receive argument without generating executable code or changing guest vtables at runtime. Gate dispatch validates the original module-relative site and identifies its mapped module from the gate return PC.

Connect and driver start use full-register conditional entry gates. Each saves/restores x8, the original caller LR and SP on both paths. Unbound calls execute the original first instruction and continue at entry+4; bound calls record the corresponding request and return through the original function's standalone `ret`. Forwarding connect as an ordinary C call would lose the ninth stack argument. The branch-gate template, destination and metadata are independently checked by `dm/verify/structck.py`; the input checker verifies the original module and method windows.

`tools/check_engine_input.py` verifies the original module ID, all three NSO segment hashes, the queue/lifecycle method windows and prior call-site anchors. The rewriter also checks every replaced byte. Use the owner's original modules:

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

## Lifecycle boundary

Attach begins with a pending binding: `connected=false`, `failed=false`. The engine's connect method latches a request, observable by `dm_net_remote_connect_requested`. The separate start method similarly latches `dm_net_remote_start_requested`, suppressing the original backend. Can-connect is true while the binding has no connect request or failure; start alone does not report a connection. A prepared native coordinator must separately call `dm_net_remote_activate` after it has verified the remote setup and made the packet pump usable. Only both conditions together report connected. Neither a writable TCP socket nor this local state flag proves gameplay admission; the coordinator is not yet wired to a real ladder session.

Engine hard/graceful close, native transport failure and queue overflow transition the binding to terminal failure. They clear pending packets and connected status, retain currently borrowed spans, and suppress the original backend even on repeated connect/status/send calls. The first failure is retained. Reconnection requires a new generation after the engine is quiescent and the previous binding has been detached; late callbacks cannot reactivate it. These gates do not prepare the original driver's role, invoke the frontend join flow or choose a save mount.

Intercepting the original graceful-close method currently terminates the local binding. A protocol-level leave/flush, journal finalization and server-save receipt are not implemented by that gate. It must not be presented as a confirmed graceful server logout or saved character.

There is one engine consumer per receive channel. Received spans stay valid until that channel's next poll. Asynchronous close retains the current span; detach requires quiescent consumers. Input is copied before a producer returns.

## Checks and limits

The independent ARM64 assembly test covers original prologue/conditional-branch continuation, status and close results, hidden output, padding canaries, remote routing, retry retention, span lifetime across close, stale generations and overflow. The start/connect fixtures enter the real assembly `dm_gate` and verify all nine argument positions, x8, NZCV, caller SP/LR and both bound/unbound paths. These checks also pass AddressSanitizer/UndefinedBehaviorSanitizer. The test's small dispatcher is independent of production module lookup; the native game run separately checks the real metadata dispatcher.

A bounded isolated native Mac run reached the offline world and traced 327 actual queue packets: 96 outgoing, 230 incoming gameplay and one incoming system packet, across 62 opcode/length combinations. This verifies the default forwarding path in the actual engine, not an actual remote/ladder game. The remote binding path currently has component-test evidence only.

After adding the first lifecycle gates, a bounded isolated native Mac run reached the world and traced 303 packets (96 outgoing, 206 incoming gameplay, one system). After adding the separate start/can-connect gates, final 40/55-second runs remained in main-menu loading; a control run using the previous module also stalled there. These later runs do not validate the final full-engine path or establish that the new gates caused the stall. Independent LLVM structure verification and native assembly tests pass for all final gates. The new C and common assembly compile for ARM64 iOS; no updated full iPhone application has been installed or device ladder game verified by these checks. Headless Mac runs with an incomplete shader cache are not rendering/FPS evidence.

`DM_NET_ENGINE_TRACE=/path/to/private.jsonl` records opcode, length, direction and sequence without payload, character or account identity. Use a fresh private path for a bounded run.

Remote role bootstrap, verified stock packet sizing, TCP framing/compression, environment/admission semantics and a real server-character save/readback still require implementation and end-to-end verification.
