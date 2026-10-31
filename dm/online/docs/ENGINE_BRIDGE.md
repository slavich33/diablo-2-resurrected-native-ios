# ARM64 packet-pump integration

The optional build-time `DM_NET_ENGINE_BRIDGE=1` cuts instrument two existing
virtual calls in Switch build 3.3.94012. They **forward the original methods**;
they do not create an online session or replace the local client with TCP.

| Call site in `main` | Original call | Inputs |
| --- | --- | --- |
| `0x2cec94` | `blr x8`, client send | `x0`: client; `x1`: begin/end byte span |
| `0x2cfa5c` | `blr x9`, client receive | `x0`: client; `x1`: error output; `x8`: indirect optional-span result |

The receive output is a 24-byte `{begin:u64,end:u64,present:u8,padding}`. A
normal Apple C call does not preserve the Horizon hidden result argument.
`hle_net_engine.c` forwards it explicitly, matching the guest-call convention
used elsewhere in the host. The independent assembly fixture checks argument
forwarding, the target call, return value, hidden output, error output and
untouched padding.

`tools/check_engine_input.py` checks all three original NSO segment hashes,
the module ID, the two indirect call windows, and the existing command/system
delivery anchors. The rewriter additionally checks the exact replaced bytes.
Unsupported original inputs must be rejected before enabling hooks.

On a Mac, using the owner's original module inputs:

```sh
python dm/online/tools/check_engine_input.py /path/to/ExeFS/main
DM_NET_ENGINE_BRIDGE=1 DM_RULESET=touch-run-v4 \
  python dm/tools/patch_nso.py /path/to/ExeFS/main /path/to/output main
dm/online/Tests/NativeTransportABI/engine.sh
```

Build `sdk` and other required modules with the same source/tool versions as
usual. A full device build must embed the rewritten main module; this flag is
not a runtime switch and performs no executable-memory modification on iOS.

`DM_NET_ENGINE_TRACE=/path/to/private.jsonl` optionally records packet opcode,
length, direction and sequence. It records no payload, character, token or
account identity. Use a fresh private path for a bounded diagnostic run.

The existing `GamePacketBridge` is a separate incremental decoder for bytes
**after transport processing**. These cuts do not attach it or raw TCP to the
engine. Remote client/server role bootstrap, verified stock packet lengths,
transport framing/compression, environment/admission handling and live
server-character round trips remain required.
