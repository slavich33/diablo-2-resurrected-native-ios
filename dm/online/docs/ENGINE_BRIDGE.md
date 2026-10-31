# ARM64 client lifecycle, packet queues and remote binding

The optional build-time `DM_NET_ENGINE_BRIDGE=1` cuts instrument the client queues, lifecycle methods and startup-input function in Switch build 3.3.94012. Without an explicit remote binding they resume the original methods. No TCP connection or admission is created at app startup.

| Method entry in main | Client vtable slot | Inputs |
| --- | --- | --- |
| `0x2c4dd0` | startup input, not a vtable method | x0: original packed startup input |
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

Connect, driver start and startup-input preparation use full-register conditional entry gates. Each saves/restores x8, the original caller LR and SP on both paths. Unbound calls execute the original first instruction and continue at entry+4; bound start/connect calls record the corresponding request and return through the original function's standalone `ret`. The startup gate resumes the original body only after applying a prepared input; a bound failure returns false through `0x2c50e8` before original startup runs. Forwarding connect as an ordinary C call would lose the ninth stack argument. The branch-gate template, destination and metadata are independently checked by `dm/verify/structck.py`; the input checker verifies the original module and method windows.

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

The Swift packet layer includes 126 fixed server-game packet lengths and eight native variable formats, exposed through C without invoking guest handlers. All 175 descriptors match both exact ARM64 input and an independently pinned Windows reference; the variable rules have separate native-reader/capture evidence. Fifteen variable formats, system-channel rules and transport processing remain open; this partial resolver must not activate a production game pump. See `CONTROL_PROTOCOL.md`, `tools/verify_stock_lengths.py` and `tools/verify_game_packet_capture.swift` for reproduction and limits.

Each queue is capped at 256 KiB/1024 packets, with 64 KiB per packet. A short outgoing buffer retains the packet for retry. Overflow is terminal and observable through `dm_net_remote_error`; it does not silently drop commands and continue. Closed bindings remain attached until explicit detach, so an interrupted remote game cannot fall back to local queues. Generation IDs reject late network callbacks from a previous connection.

## Lifecycle boundary

Attach begins with a pending binding: `connected=false`, `failed=false`. The engine's connect method latches a request, observable by `dm_net_remote_connect_requested`. The separate start method similarly latches `dm_net_remote_start_requested`, suppressing the original backend. Can-connect is true while the binding has no connect request or failure. A prepared native coordinator must separately call `dm_net_remote_activate` after it has verified the remote setup and made the packet pump usable. Connected requires readiness **and either start or connect**. The original frontend callback at `0x2cfb40` waits for connected after the start path; requiring a separate connect call would keep that path pending forever. A request alone, readiness alone, a writable TCP socket and this local state flag do not prove gameplay admission; the coordinator is not yet wired to a real ladder session.

Engine hard/graceful close, native transport failure and queue overflow transition the binding to terminal failure. They clear pending packets and connected status, retain currently borrowed spans, and suppress the original backend even on repeated connect/status/send calls. The first failure is retained. Reconnection requires a new generation after the engine is quiescent and the previous binding has been detached; late callbacks cannot reactivate it. Queue/lifecycle gates do not invoke the frontend join flow or choose a save mount.

Intercepting the original graceful-close method currently terminates the local binding. A protocol-level leave/flush, journal finalization and server-save receipt are not implemented by that gate. It must not be presented as a confirmed graceful server logout or saved character.

## Prepared remote startup input

The native coordinator can now call `dm_net_remote_prepare_start(generation, host, port)` before invoking the original frontend flow, while the engine is quiescent. This is one immutable configuration per generation, not an instruction to connect or evidence of admission. The host must be 1..23 ASCII letters/digits/dots/hyphens and port 1..65535; overlong hosts are refused, never truncated. Resolve a longer service hostname to a suitable endpoint separately. The binding owns a copy of the address. Replacing a prepared/applied configuration or preparing after start/connect returns `DM_NET_BUSY`.

The exact-build startup gate uses the mapped main module's original client at `main+0x2d9f438`. For that bound client it checks the input capacity, one-shot preparation and original mode zero before changing only the 24-byte host field at `+0x21`, mode u32 at `+0x39` to 6 and port u16 at `+0x9d1`. It then resumes the original startup-input function. The original function copies these values into its normal globals and runs its original client path. No executable page or vtable is modified at runtime.

Missing preparation, repeated application, a different original mode, failure or late start/connect refuses the bound startup. The gate returns false before original startup, without falling back to an offline world. Invalid inputs are unchanged. An unbound startup is unchanged. Tests check the real assembly branch gate in prepared, refused and unbound cases, all preserved argument positions, exact modified byte ranges, string ownership, capacity/null failures and stale generations.

**Before this preparation**, the real coordinator must verify the server environment/admission and choose an isolated downloaded server-character scope. The original remote path emits character-data commands: pointing it at offline saves could send those saves to a peer. This API does not choose a save path, authorize a character, implement the stock TCP codec, activate a packet pump or offer a working Join button. The account screen remains disconnected from this unfinished coordinator.

A bounded isolated native Mac experiment using a loopback TCP fixture confirmed the prepared remote path generates the original `0x68` join request, `0x6d` heartbeat and `0x6c` character-data commands after receiving a controlled initial `af00` system message. The fixture's four-byte outbound record lengths are **test framing**, not a derived production TCP format. Its peer does not admit a player or run a game; it uses a disposable local save copy, no production API and no phone changes. This is frontend/engine integration evidence, not a ladder join, supported Server Saves mode or remote-world rendering.

There is one engine consumer per receive channel. Received spans stay valid until that channel's next poll. Asynchronous close retains the current span; detach requires quiescent consumers. Input is copied before a producer returns.

## Checks and limits

The independent ARM64 assembly test covers original prologue/conditional-branch continuation, status and close results, hidden output, padding canaries, remote routing, retry retention, span lifetime across close, stale generations and overflow. The start/connect fixtures enter the real assembly `dm_gate` and verify all nine argument positions, x8, NZCV, caller SP/LR and both bound/unbound paths. These checks also pass AddressSanitizer/UndefinedBehaviorSanitizer. The test's small dispatcher is independent of production module lookup; the native game run separately checks the real metadata dispatcher.

With the current startup/queue/lifecycle gates, a bounded 55-second isolated native Metal-3 Mac run reached the offline world and traced 259 packets: 25 outgoing, 233 incoming gameplay and one incoming system packet. A separate 55-second run exercised the actual prepared startup gate and production metadata dispatcher with a loopback fixture: one controlled system greeting and 17 original outgoing join/heartbeat/character-data commands. No remote world or server admission was supplied. These runs distinguish default forwarding from the prepared remote-client path; neither proves live ladder play.

Independent LLVM structure verification passes for the final rewritten main, including all three conditional network gates. Native assembly checks and ASan/UBSan pass; the changed C compiles for ARM64 iOS. No updated full iPhone application was installed or device ladder game verified by these checks. Earlier default Metal-4 menu waits also affected an old-module control; those waits did not establish that network gates caused a regression. Headless Mac runs with an incomplete shader cache are not rendering/FPS evidence.

`DM_NET_ENGINE_TRACE=/path/to/private.jsonl` records opcode, length, direction and sequence without payload, character or account identity. Use a fresh private path for a bounded run.

`tools/verify_engine_start.py /path/to/ExeFS/main` independently checks the original ARM64 start/status ordering with bounded, development-only Unicorn execution. It verifies the entire original NSO first, replaces only resolver/clock/generic-storage calls with isolated stand-ins, and never invokes an OS, network or game entry point. Original start selects state 2; status is false while that backend is pending, true after its modeled completion without calling connect, and false after backend failure. The native ABI tests cover start-only/connect-only readiness in both orders and terminal failure. This reference does not implement remote-role preparation or prove a live backend connection.

The complete coordinator/frontend launch context, verified stock packet sizing, TCP framing/compression, environment/admission semantics and a real server-character save/readback still require implementation and end-to-end verification. The prepared startup transition covers one identified remote-client path; it does not establish complete ladder role/bootstrap compatibility.
