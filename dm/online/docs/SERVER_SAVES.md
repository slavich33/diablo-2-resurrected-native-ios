# Server Saves: native read-side preparation

`serverSaveManifest` reads `GET /characters/saves?ladderId=...` with a narrow
game token and `X-Ladder-Launch-Ticket`. Both must be current and the ticket
must name the requested ladder. HTTP refusal is returned to the caller without
credential substitution or retry. The launcher's long-lived token is not used
for save reads.

The native list decoder requires `ladderId`, `serverAuthoritative` and `saves`.
The returned ladder must match the requested ladder and the snapshot's scope
before any staging. An accepted live native response confirmed this root shape
with an empty `saves` array. The old inferred `files` key was incorrect and is
not accepted as a fallback. An absent authority field or incompatible response
fails rather than implying local progress may be uploaded.

On 31 October 2026 a signed native macOS probe with the actual native shell
application version `1.0` obtained a launch ticket for the freshly verified
revision-5 package. `GET /characters/saves/health` returned 204 and the public
native manifest reader accepted `GET /characters/saves` with 200, the expected
ladder, `serverAuthoritative=true` and zero files. A narrow game-token revoke
request was accepted afterwards. No server character was created or changed.
This proves ticket/list access, not a game admission, file download or saved
character round trip.

On the physical iPhone, build `1793472407` subsequently verified the complete
signed revision-6 archive locally, obtained its own launch ticket/narrow token
and accepted the same typed empty server-authoritative save response (200).
The phone also read the player lobby and received 204 for its token-revocation
request. This removes a Mac-only dependency for those API reads; per-file
metadata and actual downloads were still unverified at that stage. The later
fresh-character test below verified one initial header; gameplay progress/save
round trips remain unverified. See [LADDER_PACKAGES.md](LADDER_PACKAGES.md).

The earlier probe used a manually supplied debug value `0.1.0` and was refused
with 403 because the minimum was 0.19.7. The native iOS shell already declared
`CFBundleShortVersionString=1.0`; that application version was independently
read from the built app. `NativeClientIdentity` now derives the version from
the calling app's metadata, and the default ticket overload uses it. Requests
identify the native platform and distinguish application version from the API
component version. An unversioned executable cannot use that overload. No
Windows platform, binary hash, plugin behavior or game compatibility is claimed
by the application version or returned ticket.

Per-file `fileName`, `sha256`, `version` and `byteCount`, with optional
`characterName`, `corrupt` and `lastSavedAtUtc`, were initially inferred from
plugin inspection. The physical fresh-character test subsequently accepted one
real nonempty entry with those fields and downloaded matching bytes. The
server also returned `kind` and `saveVersion`. Corrupt-file handling and full
progress/stash entries still need live verification.

`downloadServerSave` reads raw bytes from `GET /characters/saves/{fileName}`
with the ladder query and the same narrow credentials. Static inspection found
the plugin constructing this route, issuing GET and hashing its response body.
The native method checks the manifest's exact byte count and SHA-256. A newer
server version fails verification instead of overwriting an existing snapshot.
The native HTTP/download limit is 8 MiB per file; the decoder's larger local
staging limit does not bypass it. Filename percent signs, Unicode and fragment
characters are escaped as a single path component. A native live download of
an initial 403-byte file is now verified below; gameplay-progress downloads and
the Unicode/percent filename cases remain outside that live observation.

`VerifiedServerSave` verifies byte count and SHA-256 before staging.
`ServerSaveSnapshot.stage` commits a complete set into a new isolated account
and ladder generation, with a same-parent directory rename. A failed or
incomplete set leaves previous generations and offline saves intact. It does
not activate a mount. Windows-to-Switch layout and serializer compatibility
still need independent verification. Optional `switchVersion105` staging now
places each unchanged file at `<stem>/<stem>.d2s` or `.d2i`, as required by the
native host. It checks the save magic and version 105 (and declared character
file length) before creating any generation. This is a header preflight, not
an item-stat/quest parser, a checksum validator or a format migration. An
isolated native Mac run loaded the prepared directory made from local phone
backup fixtures and reached the world. A genuine Windows/server save round
trip for actual gameplay progress is still unverified; no server authority mode
is inferred from that isolated fixture test.

Local staging accepts only `.d2s`/`.d2i` names without path separators, control
characters or Windows-reserved path characters. Case and normalized-name
collisions are refused. Local resource limits are 1024 files, 16 MiB per file
and 128 MiB per snapshot; these are client memory limits, not server promises.

The inspected plugin supports a server-authoritative mode in which the game
server saves progress and local edits are not uploaded; new-character
registration is separate. The accepted revision-5 account list reported
`serverAuthoritative=true`; that does not authorize importing existing offline
characters or establish the write/registration contract. No general progress
upload, provenance API, deletion or offline-character import is implemented
here. The existing offline save path remains separate.

## Fresh-character registration

`NewCharacterJournal` records one fresh engine-created header, exact request
bytes and a 64-character lowercase hexadecimal operation ID in an account/ladder
namespace (SHA-256 of 32 securely random bytes, matching the plugin). The local account
namespace uses the JWT subject only as a path hint, not as authentication; the
actual bearer is authorized by the server before the journal is prepared.
Token rotation does not change the namespace and tokens are never written to
the journal. File/parent synchronization and a separate file lock precede the
first HTTP POST. A reload or another journal instance cannot resend an attempted
operation. An uncertain result is reconciled by its receipt; 404 after an
attempt does not authorize another POST or a replacement operation.

The narrow registration request is `POST /characters/saves/snapshot` with a
ladder query, game token and matching launch ticket. It contains bundle identity,
operation ID and one `fileName`/`contentBase64` entry. Fresh creation omits
`expectedVersion` and has no deletion or progress/provenance fields. This
contract was derived from the unchanged signed revision-6 Server Saves plugin.
The coordinator refuses an existing server character, checks a separate
`GET /characters/saves/snapshot/receipts/{operationId}`, reads the new manifest
and downloads digest-checked bytes. Only matching receipt and exact initial
header readback confirm the journal. Downloaded files are staged as a new
isolated Switch-layout generation, without activating `DM_SAVE`. The narrow
token is revoked on success and failure.

The first physical-device attempt stopped at receipt lookup with HTTP 400
before any POST. The initial implementation used a GUID; the inspected plugin
instead generates a 64-character digest. The journal migrates a legacy GUID
only while it is durably `prepared`, retaining the old unsent identifier for
audit. An attempted/unknown operation is never replaced by this migration.

Build `1793475741` (code `48fc46e`) subsequently completed the real iPhone
registration: initial receipt lookup 404, one snapshot POST 200, separate receipt
GET 200, nonempty manifest and matching binary download. The server reported
one character at version 1, save version 105, 403 bytes; the source header's
modern preview identifies Reign of the Warlock. The journal was independently
copied from the phone in confirmed state, with matching ladder, receipt digest
and downloaded bytes in isolated generations. After an explicit process
restart, receipt and download succeeded again with the same operation ID,
one server character/version 1 and no creation POST in the new run. Twenty
offline-save files independently read before/after app updates were unchanged.
The original engine and game TCP session were not started; this is initial
character persistence, not saved gameplay progress or playable ladder.

An explicit device-test switch `DM_ONLINE_REGISTER_DIAGNOSTICS=1`, alongside
the package inspection switches, uses only the dedicated original-engine
creation directory and a supplied expected hash/name input. It never scans the
offline save directory. Its reply diagnostics retain response shapes and
bounded error codes, not headers, tokens or response values. This development
path is not a generic save importer or a playable-ladder claim.

`NewCharacterHeader` preflights a version-105, 403-byte creation header from
the original engine before any world entry. It checks the declared length,
checksum, initial-character flags, level one and matching ASCII name. It
rejects full/progress saves, mismatched names and unsupported formats without
editing bytes or making HTTP requests. Passing it is not proof of provenance
or server acceptance: the caller must use a fresh isolated creation, and the
server remains authoritative. The layout was cross-checked against the pinned
MIT-licensed D2SSharp [Character](https://github.com/ResurrectedTrader/D2SSharp/blob/510bfaa1b5535454fb3d688d78b7cd3b0c171d76/src/D2SSharp/Model/Character.cs)
and [PreviewData](https://github.com/ResurrectedTrader/D2SSharp/blob/510bfaa1b5535454fb3d688d78b7cd3b0c171d76/src/D2SSharp/Model/PreviewData.cs)
readers and an actual original-engine creation on iPhone. It also checks the
modern preview game-edition field and valid classes for that edition; the
initialization flag alone does not identify Classic versus an expansion.
Public tests contain
only synthetic layout bytes, not a character save. This preflight is not yet
connected to a product registration button or a general save-upload API.

An independent D2SSharp 0.0.22 reader/writer (the dependency pinned by Reimagined Launcher v0.19.7) round-tripped the two local backup samples, character and shared stash, byte-identically. This held with embedded vanilla tables and with both primary/base text-table datasets extracted and hashed from the signed revision-4 ladder package. This is two-sample offline format evidence, not a server save receipt or a claim about all modded items. The .NET tool is a Mac development reference, not part of the native iOS game.

The [read-only reference tool](../tools/SaveReference) is included as source for
reproduction on a Mac/desktop with .NET 10. It uses the pinned MIT-licensed
[D2SSharp](https://github.com/ResurrectedTrader/D2SSharp) package and prints
anonymous counts/results, without paths, character names, save bytes or writes:

```sh
dotnet run --project dm/online/tools/SaveReference -- /path/to/own/save-samples
dotnet run --project dm/online/tools/SaveReference -- /path/to/own/save-samples /path/to/validated/version105/tables
```

Repeat for each applicable primary/base dataset. The tool does not validate
bundle signatures or establish live game/server compatibility.
