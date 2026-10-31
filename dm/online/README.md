# Native Reimagined online client research

[中文](README.zh-CN.md)

This is an experimental native Apple client for the public Reimagined launcher API. The goal is to implement the missing client components and integrate them into the iOS port, potentially enabling iPhone users to participate in the existing Reimagined ladder.

**This module does not enable multiplayer or ladder gameplay.** A physical iPhone verified all 3,814 files of the signed revision-6 package, obtained native launch tickets/tokens, read the live player lobby and registered one original-engine-created character header. A separate server receipt, manifest and download matched the initial 403-byte version-105 Reign of the Warlock header exactly. After a process restart, the same operation resumed through receipt/download without another creation POST. Sign-in, authenticated region reads and session persistence were also verified. A native macOS probe separately received a game endpoint's initial `af 00`, sending zero bytes. The engine/save mount remains disconnected; game admission and a character's actual gameplay progress/save/reload have not been verified.

Implemented:

- Native HTTPS schedule and client-policy reads, with policy revision/date consistency checks.
- PKCE authorization URL, bounded loopback callback listener, callback validation, and the documented authorization-code exchange request.
- Local application Keychain session storage, refresh/revocation requests and an explicit native-client sign-out command.
- Complete local ZIP32 package validation with caller-pinned P-256/P1363 trust keys: archive/manifest SHA-256, signed descriptor consistency and every file digest. The resulting proof is bound to fresh policy metadata before requesting a ticket. This does not implement the bundle's native plugins; see [LADDER_PACKAGES.md](docs/LADDER_PACKAGES.md).
- D2EM v3 outer-envelope framing: bounded little-endian fields, duplicate-ID rejection and unknown-required-field rejection. Field payload semantics and game admission remain unimplemented.
- D2RL v1 control-message codec, bidirectional control carrier and bounded environment-manifest fragmentation/assembly. See [the partial protocol observations](docs/CONTROL_PROTOCOL.md); server reply semantics and live interoperability remain unverified.
- Shared D2RL 1..11 envelope framing and opaque routing, plus the specific kind 11 oversized client-command fragment codec/assembler. Native bytes matched 2054 bounded reference cases; this is not complete admission, TCP framing or wide engine handlers.
- Incremental game-packet decoder and caller-serialized C polling bridge, with a required engine length callback, bounded buffering, retained output retry and terminal malformed/truncated-packet errors. This layer runs after transport processing and is not yet attached to the engine or raw production TCP.
- Native TCP byte transport using Network.framework, with nonblocking C polling exports for a future verified engine adapter. Receive/send queues are bounded; backpressure, peer EOF and errors are observable. It does not implement D2RLoader packet framing or admission.
- Opt-in ARM64 engine queue/lifecycle gates, pending/active/failed binding state and argument-preserving entry gates. A one-shot prepared startup transition applies the identified remote-client mode/address/port; incomplete preparation returns false before local startup. A bounded native loopback fixture elicited the original join/character-data commands. Failed sessions never resume local queues; unbound methods remain available. Full launch context, production transport and admission remain incomplete.
- Narrow game-session token issuance/revocation and ladder launch-ticket request contracts, including expiry and bundle-identity checks. No automatic fallback to a launcher token.
- Native platform identity and an application-version ticket overload using the app's actual `CFBundleShortVersionString`. The old manual debug value was not the native shell's version; an unversioned executable cannot use the new overload.
- Native Server Saves list/file decoding and isolated staging. Physical-device verification covered one newly registered initial header and its nonempty metadata, separate receipt and exact download; full gameplay-progress saves remain unverified.
- Version-105 new-character header preflight and a durable one-time registration journal: exact initial header only, independent receipt/download verification, account/ladder isolation and no resubmission after an unknown outcome. A native iPhone creation/readback/restart test passed; existing offline characters are not imported.
- Native read-only player lobby and selected-game resolution using narrow credentials, bounded IDs, typed environment summaries and validated endpoint/game-number fields. Both typed readers accepted live replies; see [GAME_LOBBY.md](docs/GAME_LOBBY.md). Server summaries never stand in for the native client's own fingerprint.
- Per-account/per-ladder local save directory preparation that does not copy, move, upload or enumerate characters. The live game's `DM_SAVE` mount is not switched.
- A macOS probe using an identifiable native-client User-Agent, read-only by default.

The authorization request follows the public launcher's random loopback-port callback contract. The CLI writes the authorization URL to a caller-selected file for opening in a browser. The iOS screen uses an in-app Safari view for website authorization and the same loopback/API/Keychain components; physical-device sign-in, authenticated region reads and session persistence were verified. No credentials or production trust roots are bundled. A fixture contains only a public test key and a signature generated by .NET 10; its private key was discarded.

## Run

```sh
swift test --package-path dm/online
swift run --package-path dm/online reimagined-probe
# Independent C caller and POSIX TCP peer; no game or account is used.
bash dm/online/Tests/NativeTransportABI/run.sh
# Explicit browser sign-in; choose a private output path outside the repository.
swift build --package-path dm/online
D2R_PROBE_BIN="$(swift build --package-path dm/online --show-bin-path)/reimagined-probe"
# For a persistent development session, sign this executable with your own
# stable identity before signing in; keep the same identifier on updates.
# codesign --force --sign "<YOUR_SIGNING_IDENTITY>" --identifier org.d2rmobile.reimagined.probe "$D2R_PROBE_BIN"
"$D2R_PROBE_BIN" --login-url-file /tmp/reimagined-authorize-url
"$D2R_PROBE_BIN" --signed-schedule
"$D2R_PROBE_BIN" --inspect-ladders  # authenticated policy, compatibility and region reads
# Explicit authenticated API check: issues and immediately requests revocation
# of a short-lived game token; never joins a game or writes a character.
"$D2R_PROBE_BIN" --check-game-token
"$D2R_PROBE_BIN" --sign-out
```

The library supports iOS 16+ and macOS 13+. The command-line probe runs on macOS. Its default mode only reads `GET /ladders/schedule` and `GET /ladders/active`. An empty anonymous list does not establish what an authenticated user sees. Both lists also returned empty after the authorized native-client sign-in on 2026-10-30; this is a time-specific observation, not a claim that the service has no ladders.

## iOS integration

`dm/ios/project.yml` compiles the client sources into the app. `dm/ios/Sources/dm_online.swift` provides the native UIKit account screen with sign-in, explicit sign-out, schedule refresh, policy-checked ladder selection and server-region preferences. No Join/Play action is exposed while game-engine admission and server saves are disconnected.

The pause menu's **More → Reimagined Online** entry shares the native tools sheet with diagnostics. The diagnostic-sharing action is retained. All new game UI strings are registered in `dm/i18n/ui_text.tsv`.

For an account-screen-only launch, use `-mode online`. That mode does not start the game host. The on-device overlay still needs regeneration and the complete app needs a build before the new pause-menu label is visible. The screen can read available metadata; it does not install a ladder package, obtain admission or modify character saves.

Verification: 57 library tests pass, including real loopback TCP transfer, refused save reads, isolated snapshot readback, loader frames/fragments, native identity and the player lobby/resolve contracts. Independent C/POSIX transport and packet checks and an ARM64 assembly engine-call ABI check passed earlier. On 2026-10-31 a complete development app was built, signed, installed over the existing application and read back on a physical iPhone running iOS 27.0.1. Its character-selection rendering and native account screen were captured on-device; the latter read one live ladder while signed out. A character save independently read before and after installation matched by SHA-256. This verifies the update, startup and anonymous account-screen path, not device sign-in, world gameplay, game admission or saved ladder progress.

The optional build-time engine-call shims and their exact ABI are documented in [ENGINE_BRIDGE.md](docs/ENGINE_BRIDGE.md). They route explicitly bound queue/lifecycle calls, prepare one remote startup path and forward original unbound methods. The full coordinator and production TCP attachment remain unfinished. The inferred Server Saves metadata reader and isolated, digest-checked snapshot preparation are documented in [SERVER_SAVES.md](docs/SERVER_SAVES.md); no live native save round trip is claimed.

Production verification on 2026-10-30: a developer-signed native macOS probe completed PKCE login, issued a game-session token, requested its revocation, and independently received HTTP 401 when reusing the still-unexpired token. A changed executable signed with the same client identity also read its saved session successfully. The subsequent version refusal was traced to an arbitrary manual debug value, not the native shell's application version. On 2026-10-31 the actual app version from bundle metadata was used with an explicit native-platform User-Agent; the server accepted a ticket for the verified revision-5 package. Live save-list and player-lobby reads then succeeded. This is not game admission or a server-character write.

The probe uses its own Keychain namespace, separate from the iOS app. For repeated development builds, sign the probe with a stable signing identity and identifier `org.d2rmobile.reimagined.probe` before signing in. An ad-hoc executable may lose access to its item after a rebuild. The CLI disables process-local legacy-Keychain dialogs, so a denied access fails promptly rather than hanging. No existing protected legacy item is deleted or migrated.

The read-only engine-input check validates the original Switch `3.3.94012` NSO module ID, all three decompressed segment hashes and the existing command/system-delivery call-site windows. It neither installs hooks nor verifies runtime admission. Use `python3 dm/online/tools/check_engine_input.py /path/to/original/ExeFS/main`. The C transport port argument is 32-bit at the host boundary to avoid the Apple/Horizon sub-32-bit calling-convention difference described in `dm/host/hle.h`.

## Remaining integration

1. Extend the verified physical-device authorization and authenticated policy/region path to the remaining game/save coordinator. Device sign-in, one selected ladder, eight regions and session persistence across restart are verified; an actual ladder game remains unverified.
2. Complete package acquisition/trust configuration in the iOS product and implement the native environment/plugin contract. The native complete-archive verifier and an opt-in device API inspection are implemented; private validation covered complete signed packages. The gameplay compatibility contract remains incomplete.
3. Connect the C transport ABI (`dm/ios/Sources/OnlineTransport.h`) to verified native game-engine callbacks and implement the D2RLoader gameplay environment handshake and packet framing. Public plugin-network interfaces do not provide this implementation.
4. Bind the prepared save namespace before mounting `DM_SAVE`, then implement native Server Saves behavior, compatible character serialization, conflict handling and confirmed server round trips. Directory preparation is not server synchronization.
5. Authorized staging tests of join, play, disconnect, reconnect and accepted server-save round trips.

A Windows User-Agent cannot supply these pieces. The published launcher HTTP contract has no Windows-only request field in its PKCE token exchange; gameplay compatibility is a separate question. The port's current `hle_net.c` and `hle_account.c` deliberately return offline errors, and its gameplay hooks must be reviewed before enabling any network path.

## Sources and attribution

This fork builds on [jhaizhou-ops/d2r-mobile](https://github.com/jhaizhou-ops/d2r-mobile), retaining its MIT license and credits. It contains no game files, shader caches, saves, signed applications, Windows loader binaries, or credentials.

The independently implemented HTTP contracts were checked against [Reimagined Launcher commit c77f983](https://github.com/D2R-Reimagined/reimagined-launcher/tree/c77f983fe40983f7d747ccc788065af9d4cd43ce), especially `ReimaginedApiHttpClient`, `LauncherAuthenticationService`, `LadderScheduleResponse`, and `LadderBundleService`.

[D2RLoader PluginSDK](https://github.com/D2RLoader/PluginSDK) publishes Windows x64 plugin contracts. The [Installer README](https://github.com/D2RLoader/Installer#readme) explicitly states that the loader core is closed source. The [TCP/IP guide](https://d2rloader.net/tcp-ip.html) describes its independent restoration of TCP/IP multiplayer. Blizzard's [2021 beta FAQ](https://news.blizzard.com/en-us/article/23688836/play-diablo-ii-resurrectedtm-during-the-early-access-open-beta) attributes removal of the original TCP/IP mode to potential security risks; it does not describe those risks in detail.

The raw TCP transport follows the official [D2RLoader TCP/IP guide](https://d2rloader.net/tcp-ip.html) (default TCP port 4000). Token/ticket contracts and save-directory separation were checked against `ReimaginedApiHttpClient`, `GameTokenResponse`, `LadderLaunchTicketResponse` and `LadderSaveDirectoryService` at the launcher commit cited above.

### Offline encoder reference

The control codec and send builders match 576 bounded offline reference cases from the pinned official core. 117 selected outputs/rejections are checked by the native Swift tests; see [the partial protocol and reproduction instructions](docs/CONTROL_PROTOCOL.md). These are component checks, not a confirmed ladder/game connection.
