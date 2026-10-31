# Native Reimagined integration: source and verified status

Updated 2026-10-31. This is the public source fork at [slavich33/diablo-2-resurrected-native-ios](https://github.com/slavich33/diablo-2-resurrected-native-ios), based on [jhaizhou-ops/d2r-mobile](https://github.com/jhaizhou-ops/d2r-mobile). Upstream authorship and the MIT license are preserved. Our current development branch is `reimagined-ios-online`.

The base project runs the user's own Switch ARM64 game program through native platform services on iOS/macOS. Our additions develop a native client for the existing Reimagined infrastructure. **Joining a Reimagined ladder game from iPhone is not yet implemented or verified.**

## Source map

| Component | Source |
| --- | --- |
| Native API, PKCE, Keychain, manifest/envelope primitives | [`dm/online`](../dm/online) |
| Native TCP stream and polling C interface | [`GameTCPStream.swift`](../dm/online/Sources/ReimaginedClient/GameTCPStream.swift), [`OnlineTransport.h`](../dm/ios/Sources/OnlineTransport.h) |
| Control-payload codec and partial protocol | [`ControlMessage.swift`](../dm/online/Sources/ReimaginedClient/ControlMessage.swift), [`CONTROL_PROTOCOL.md`](../dm/online/docs/CONTROL_PROTOCOL.md) |
| Incremental game-packet decoder and C polling bridge | [`GamePacketStream.swift`](../dm/online/Sources/ReimaginedClient/GamePacketStream.swift), [`GamePacketBridge.swift`](../dm/online/Sources/ReimaginedClient/GamePacketBridge.swift) |
| Optional ARM64 client-call instrumentation | [`hle_net_engine.c`](../dm/host/hle_net_engine.c), [`ENGINE_BRIDGE.md`](../dm/online/docs/ENGINE_BRIDGE.md) |
| Bound client packet FIFOs and connection generations | [`hle_net_binding.c`](../dm/host/hle_net_binding.c), [`dm_net_binding.h`](../dm/host/dm_net_binding.h) |
| Server-save metadata reader and isolated snapshot staging | [`ServerSaves.swift`](../dm/online/Sources/ReimaginedClient/ServerSaves.swift), [`SERVER_SAVES.md`](../dm/online/docs/SERVER_SAVES.md) |
| iOS account UI integration | [`dm_online.swift`](../dm/ios/Sources/dm_online.swift) |
| Native Apple host and iOS app build | [`dm/host`](../dm/host), [`dm/ios`](../dm/ios) |

## Confirmed checks

Latest native component checks, 31 October 2026:

- 46 Swift tests passed, including real local TCP peers, bounded buffering, EOF, API contracts, reference vectors, mixed game/control streams, refused save reads, snapshot readback, digest failure, version mismatch, path traversal and case collisions.
- 576 offline reference cases matched the pinned official D2RLoader core: 276 control cases, 216 fragment cases, 12 carrier cases and 72 client/server control-send-builder cases. 117 reference outputs/rejections are included in the Swift fixtures. The send-builder reference intercepts queue boundaries to collect bytes; the reference tools do not run a Windows game session or a real server queue. See the partial protocol document for reproduction.
- Independent C callers verified the native TCP round trip against a POSIX peer and the packet ABI's length callback, split input, retained short-buffer retry, ordered drain and truncated EOF. The game-packet bridge is not yet attached to the engine or raw production TCP; ordinary lengths in these checks are synthetic fixtures.
- The native library and iOS UI bridge compiled for ARM64 iOS. The account UI was separately exercised in a Mac Catalyst harness.
- The queue-method cuts passed independent ARM64 assembly ABI checks and AddressSanitizer/UndefinedBehaviorSanitizer, including hidden `x8`, exact prologue continuation and remote queue failure/lifetime behavior. An isolated native Mac run reached the offline world and traced 327 real packets through the default forwarding path (96 outgoing, 230 incoming gameplay, one system). Remote routing has component-test evidence; no actual ladder binding is claimed.
- Genuine production browser authorization and authenticated API reads succeeded in a signed native macOS probe. Short-lived game-token issue/revocation succeeded; an independent repeat request with the revoked, unexpired token was rejected with HTTP 401. Session readback also succeeded after a signed probe binary update.

These checks cover components. iPhone account login, live game admission, sustained multiplayer and server-character save/readback remain unverified. Upstream performance measurements in the main README describe the original project.

On 2026-10-31, the signed macOS probe read one active Hallowing Ladder and 8 advertised/available regions. During inspection the bundle advanced from revision 3 to 4/schema 2. Both downloaded archives passed descriptor/archive hashes, pinned P256/P1363 manifest signature and all 3814 file hashes in a private inspection tool. No DLL was executed; this is not yet an integrated iOS package installer. The client refused to reuse revision 3's receipt for revision 4.

With revision 4 validated, the native probe reported its actual version 0.1.0. The launch-ticket endpoint returned HTTP 403, stating that launcher 0.19.7 or newer was required. Save reads without a ticket returned `ladder_ticket_invalid`; the temporary game token was revoked. No server-side character was created or changed. Native compatibility/version negotiation and an actual game session remain unverified.

## Remaining implementation

- Transport-level framing/compression, verified ordinary gameplay packet lengths and actual bidirectional gameplay exchange.
- Verified bindings to the ARM64 engine's client/server roles and packet queues.
- Complete required environment-manifest/admission semantics and verified native-client compatibility, including the required plugin behavior.
- Accepted Server Saves metadata/file reads and serializer/layout compatibility, engine save binding, journal/new-character/progress semantics and actual server save/readback confirmation. The inferred per-file binary GET and digest checks are implemented and fixture-tested; accepted native downloads are unverified. The read-side decoder is inferred from plugin fields; local staging tests are not server synchronization.
- End-to-end testing against a supported ladder/test environment.

Maintainer discussions: [Reimagined launcher #264](https://github.com/D2R-Reimagined/reimagined-launcher/issues/264), [D2RLoader PluginSDK #5](https://github.com/D2RLoader/PluginSDK/issues/5).

## Build and repeat checks

For the native API/transport package on a Mac with Xcode:

```sh
swift test --package-path dm/online
```

For the iPhone game app, follow the upstream [Mac source-build steps](../README.md#with-a-mac-three-steps), [dependencies](DEPENDENCIES.md), and [game-file layout](GAME_FILES.md): supply your own game files, run `./setup.sh`, configure `dm/ios/local.env` from its example, then run `./run.sh build` in `dm/ios`. Rebuild generated game/shader inputs for the exact source/tool versions used. The latest online changes have component compilation/testing evidence; a new full device build and ladder game test are still pending.

This repository publishes source, build tools and non-secret test fixtures. Game executables/assets, extracted game data, Windows loader binaries, signed app packages, signing keys, account credentials/tokens and character saves are supplied or stored locally by their owner.
