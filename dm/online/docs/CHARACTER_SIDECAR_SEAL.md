# Native version2 sidecar seal

`CharacterSidecarSeal.swift` implements the original v2 signing digest and native P-256 ECDSA sealing/verification. It is separate from the file header's ordinary payload SHA256. A valid local signature does not establish server ownership, a server save receipt, package compatibility or ladder admission.

## Signing bytes

The full original hash entrypoint validates the sidecar model and serializes its complete canonical payload in signing mode. Only the64-byte signature field at payload offsets232..<296 becomes zero. Public key, history fields, root texts, mod/plugin records and stat descriptors remain covered. The digest is:

```
SHA256(UTF8("D2RL-SEAL-V2") || 0x00 || signing_payload)
```

The domain is13 bytes including its terminating NUL; the44-byte file header is excluded. The original native/Windows model offsets differ from wire payload offsets, so no C++ structure cast is used.

The public key at payload168..<232 is64-byte `X || Y`. The signature at232..<296 is64-byte `r || s`; neither is DER in the file. Native CryptoKit signs the already-computed SHA256 digest, avoiding a second hash. Microsoft's original ECC-public-key blob has an8-byte header followed by big-endian X/Y coordinates; the original code copies those64 coordinate bytes into the sidecar. See [Microsoft ECC blob layout](https://learn.microsoft.com/en-us/windows/win32/api/bcrypt/ns-bcrypt-bcrypt_ecckey_blob), [NCryptSignHash](https://learn.microsoft.com/en-us/windows/win32/api/ncrypt/nf-ncrypt-ncryptsignhash) and [Apple P256.Signing](https://developer.apple.com/documentation/cryptokit/p256/signing).

`verifySeal(expectedPublicKey:)` can pin a separately trusted prior key. Verification without that argument checks self-consistency only. `sealed(using:)` uses the caller's own key; it refuses a signed predecessor with a different key or an invalid existing signature. It does not silently reset lineage, rotate keys or re-sign altered prior content. Constructing the next save's history remains a separate coordinator operation.

## Key persistence

`SidecarSigningKeychain` stores a dedicated32-byte native private key in a separate local Keychain service with `WhenUnlockedThisDeviceOnly`, no synchronization and no private material in game files/logs/Git. Scope is a canonical HTTPS origin plus the opaque account ID, framed and hashed for the Keychain account. Default HTTPS port, host case and trailing slash do not accidentally select a different key. Invalid scopes fail before accessing Keychain.

Existing unreadable/corrupt key data throws; it is never silently replaced. Concurrent first creation handles a duplicate by reloading the winning key. This API is not yet invoked by the game/save coordinator and does not create an actual account key merely by starting the app.

## Completed-file integrity binding

Read-only inspection of the exported original D2S-completion wrapper establishes payload checksum at8, byte count at12 and complete-file SHA256 at16..<48. The word at12 is not the game/save-format version. The16 bytes at48..<64 are the random history identifier, not the character name.

`verifySignedVersion105Save` requires a separately trusted public key, validates the seal, then applies the port's strict version105 D2S header/name/rolling-checksum/whole-digest preflight. Expected character name must come from the selected isolated server-character record. This is a local integrity check and performs no file import or HTTP write.

## Verification scope

The full original validator, signing-mode payload writer and original SHA256 matched103 own synthetic fixtures, including signature independence, public-key changes, UTF8, mod/plugin/stat records and pending zero signatures. The original hash must not modify its0x248-byte model or allocation guard. The original file codec's1077 cases are retained separately.

An ephemeral native CryptoKit signature was independently verified by OpenSSL. Its file was accepted by the original full reader, reproduced byte for byte by its writer and given the identical digest by the original signing-hash entrypoint. A separate private Keychain test confirmed persistence across two process launches and canonical-origin equivalence, using only an isolated random test service removed afterward.

A second isolated Keychain test replaced its own test key with31 invalid bytes: the store refused it and left those bytes intact rather than rotating the key. Its random test service was then removed. Actual account signing keys were not created or changed.

Local completed-file binding was also exercised against a pre-existing private copy of the previously registered initial403-byte D2S header. A synthetic history and fresh ephemeral key were used only in a separate artifact directory. The native helper rejected changed save bytes and a wrong expected character name; original reader/writer/hash checks matched the signed artifact's checksum, byte count and whole-file digest. The source header remained unchanged. This is not a gameplay-progress save, a filesystem completion notification, an import or a new server upload.

```sh
python dm/online/tools/verify_sidecar_signing_digest.py --dll /path/to/your/D2RCore.dll
swift test --package-path dm/online
```

This is not a Windows runtime on iPhone. The development reference executes only bounded original codec/hash routines on own synthetic data; it does not execute OS signing APIs, game/network entrypoints or another user's key. Production signing uses native CryptoKit/Keychain.

## Remaining integration

Native history advancement and the optional engine completion boundary are documented in [CHARACTER_SIDECAR_HISTORY.md](CHARACTER_SIDECAR_HISTORY.md) and [SAVE_COMPLETION.md](SAVE_COMPLETION.md). Received-metadata matching, genuine environment projection, complete history/reset policy, atomic D2S+sidecar commit, server acceptance and reconnect/reload still require integration. The native advertised sidecar capability remains0. No phone installation or live admission/progress-save write was performed by these checks.
