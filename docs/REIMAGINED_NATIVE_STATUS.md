# Native Reimagined integration: source and verified status

Updated 2026-10-30. This is the public source fork at [slavich33/d2r-mobile](https://github.com/slavich33/d2r-mobile), based on [jhaizhou-ops/d2r-mobile](https://github.com/jhaizhou-ops/d2r-mobile). Upstream authorship and the MIT license are preserved. Our current development branch is `reimagined-ios-online`.

The base project runs the user's own Switch ARM64 game program through native platform services on iOS/macOS. Our additions develop a native client for the existing Reimagined infrastructure. **Joining a Reimagined ladder game from iPhone is not yet implemented or verified.**

## Source map

| Component | Source |
| --- | --- |
| Native API, PKCE, Keychain, manifest/envelope primitives | [`dm/online`](../dm/online) |
| Native TCP stream and polling C interface | [`GameTCPStream.swift`](../dm/online/Sources/ReimaginedClient/GameTCPStream.swift), [`OnlineTransport.h`](../dm/ios/Sources/OnlineTransport.h) |
| Control-payload codec and partial protocol | [`ControlMessage.swift`](../dm/online/Sources/ReimaginedClient/ControlMessage.swift), [`CONTROL_PROTOCOL.md`](../dm/online/docs/CONTROL_PROTOCOL.md) |
| iOS account UI integration | [`dm_online.swift`](../dm/ios/Sources/dm_online.swift) |
| Native Apple host and iOS app build | [`dm/host`](../dm/host), [`dm/ios`](../dm/ios) |

## Confirmed checks

At source commit [`9a44620`](https://github.com/slavich33/d2r-mobile/commit/9a446209f5df4db0a07d7a4522885f3479f358d2):

- 33 Swift tests passed, including real local TCP peers, bounded buffering, EOF, API contracts and control/reference vectors.
- 504 offline encoder/boundary cases matched the pinned official D2RLoader core: 276 control cases, 216 fragment cases and 12 client-carrier cases. 45 selected reference outputs/rejections are included in the Swift fixtures. The reference tooling substitutes generic container-memory operations in a bounded CPU model; it does not run a Windows game session. See the partial protocol document for reproduction.
- The native library and iOS UI bridge compiled for ARM64 iOS. The account UI was separately exercised in a Mac Catalyst harness.
- Genuine production browser authorization and authenticated API reads succeeded in a signed native macOS probe. Short-lived game-token issue/revocation succeeded; an independent repeat request with the revoked, unexpired token was rejected with HTTP 401. Session readback also succeeded after a signed probe binary update.

These checks cover components. iPhone account login, live game admission, sustained multiplayer and server-character save/readback remain unverified. Upstream performance measurements in the main README describe the original project.

## Remaining implementation

- Full bidirectional game-stream framing and ordinary gameplay packet exchange.
- Verified bindings to the ARM64 engine's client/server roles and packet queues.
- Complete required environment-manifest/admission semantics and approved native-client compatibility.
- Server Saves integration, character isolation and actual save/readback confirmation.
- End-to-end testing against a supported ladder/test environment.

Maintainer discussions: [Reimagined launcher #264](https://github.com/D2R-Reimagined/reimagined-launcher/issues/264), [D2RLoader PluginSDK #5](https://github.com/D2RLoader/PluginSDK/issues/5).

## Build and repeat checks

For the native API/transport package on a Mac with Xcode:

```sh
swift test --package-path dm/online
```

For the iPhone game app, follow the upstream [Mac source-build steps](../README.md#with-a-mac-three-steps), [dependencies](DEPENDENCIES.md), and [game-file layout](GAME_FILES.md): supply your own game files, run `./setup.sh`, configure `dm/ios/local.env` from its example, then run `./run.sh build` in `dm/ios`. Rebuild generated game/shader inputs for the exact source/tool versions used. The latest online changes have component compilation/testing evidence; a new full device build and ladder game test are still pending.

This repository publishes source, build tools and non-secret test fixtures. Game executables/assets, extracted game data, Windows loader binaries, signed app packages, signing keys, account credentials/tokens and character saves are supplied or stored locally by their owner.
