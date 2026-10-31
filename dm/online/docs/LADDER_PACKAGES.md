# Native signed package validation

`LadderArchiveVerifier` accepts a local archive, a fresh ladder bundle
descriptor and independently pinned P-256 public keys. It verifies the entire
archive's size and SHA-256 before reading ZIP entries, then the exact manifest
bytes, SHA-256 and P1363 signature. The key is selected from the caller's trust
map, never from the archive.

The manifest's identity, revision, schema, compatibility, file inventory and
plugin inventory must agree with the descriptor. Each file's uncompressed
length, CRC and SHA-256 is verified. Paths, case/normalization collisions,
duplicate entries, extra/missing files, symlinks and overlapping local records
are refused. Plugin records must match their signed file records. No archive
contents are extracted or executed.

The bounded supported format is ZIP32 with stored or raw-deflate entries,
UTF-8 names, no encryption, no data descriptors and no separate directory
records. Unsupported ZIP features fail explicitly. Limits are 512 MiB per
archive, 20,000 payload files, 256 MiB per uncompressed entry and 4 GiB total
payload. The code uses Apple SDK `zlib`, Foundation and CryptoKit on native
macOS/iOS, with no external runtime or child process.

`VerifiedLadderPackage` has no public initializer. Its proof must match the
current policy's identity, digests, revision, schema, compatibility, size,
signature/key and normalized inventories. The proof-taking `launchTicket`
overload refuses a contradictory or newer policy before HTTP. A signed and
hash-valid Windows plugin is **not** evidence that its behavior is implemented
by the native engine. This verifier does not load plugins, mount mod data,
admit a game or establish saved progress.

`inspectLadderAccount` requests a ticket only with that proof, obtains a narrow
game token and reads the server-save manifest and player-room list. The token
is kept in memory and a revocation request is completed before return. Cleanup
is also attempted after refusal/cancellation, in an independent task so parent
cancellation does not suppress it. A cleanup failure is returned explicitly.
No launcher-token fallback, character upload or TCP connection is used.

## Physical-device development inspection

The native account screen has an explicit `DM_ONLINE_PACKAGE_DIAGNOSTICS=1`
switch. The operator supplies these files in the app's Documents directory:

```
ReimaginedPackages/<artifact-sha256-lowercase>.zip
ReimaginedTrust/<independently-pinned-key-id>.pem
```

The public key must be chosen independently of the archive. The diagnostic
does not download a key or substitute one after signature refusal. It uses the
iPhone's own Keychain session, validates the full local package on a utility
task, fetches fresh policy again and then invokes the proof-bound API reader.
No Mac credentials need to be transferred to the phone.

`online-package-state.json` records the build, phase, verified counts,
revision, save-authority flag and lobby/save counts. `online-http-state.json`
records only a bounded list of recognized route labels and HTTP statuses,
excluding URLs/identifiers, headers, tokens, bodies, character and room names.
The separate `DM_ONLINE_DIAGNOSTICS=1` switch retains the account-screen
capture described in [GAME_LOBBY.md](GAME_LOBBY.md). These are development
diagnostics, not a Join button or a general archive-import product flow.

Synthetic signed ZIP tests exercise stored/deflate and empty entries, policy
binding, independent archive/signature/file checks, unsafe paths, collisions,
malformed offsets and unsupported ZIP features. Lifecycle tests check narrow
credentials, refusals, cancellation and token cleanup. A native macOS run also
verified all 3,814 files of the real signed revision-6 package. None of those
observations proves physical-device game admission or a progress/save reload.
