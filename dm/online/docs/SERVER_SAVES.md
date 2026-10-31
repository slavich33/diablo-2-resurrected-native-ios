# Server Saves: native read-side preparation

`serverSaveManifest` reads `GET /characters/saves?ladderId=...` with a narrow
game token and `X-Ladder-Launch-Ticket`. Both must be current and the ticket
must name the requested ladder. HTTP refusal is returned to the caller without
credential substitution or retry. The launcher's long-lived token is not used
for save reads.

The route, header and metadata field names were observed in the signed ladder
package's Server Saves plugin. The native decoder requires an object with
`serverAuthoritative` and `files`, with per-file `fileName`, `sha256`, `version`
and `byteCount`; optional metadata includes `characterName`, `corrupt` and
`lastSavedAtUtc`. This inferred response schema has **not yet been checked
against an accepted native session**. Tests use synthetic fixtures. An absent
authority field or an incompatible response must fail rather than imply that
local progress may be uploaded.

On 31 October 2026 a signed native macOS probe, reporting its real version
0.1.0, was refused a launch ticket with HTTP 403: the ladder required launcher
0.19.7 or newer. Save reads without a ticket were refused with
`ladder_ticket_invalid`. No native server-character download/upload or game
admission is claimed. Native compatibility/version negotiation remains to be
agreed and tested; changing a version string alone is not interoperability.

`downloadServerSave` reads raw bytes from `GET /characters/saves/{fileName}`
with the ladder query and the same narrow credentials. Static inspection found
the plugin constructing this route, issuing GET and hashing its response body.
The native method checks the manifest's exact byte count and SHA-256. A newer
server version fails verification instead of overwriting an existing snapshot.
The native HTTP/download limit is 8 MiB per file; the decoder's larger local
staging limit does not bypass it. Filename percent signs, Unicode and fragment
characters are escaped as a single path component. The accepted native live
download remains unverified while ticket compatibility is unresolved.

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
trip is still unverified; no server authority mode is inferred from that test.

Local staging accepts only `.d2s`/`.d2i` names without path separators, control
characters or Windows-reserved path characters. Case and normalized-name
collisions are refused. Local resource limits are 1024 files, 16 MiB per file
and 128 MiB per snapshot; these are client memory limits, not server promises.

The inspected plugin supports a server-authoritative mode in which the game
server saves progress and local edits are not uploaded; new-character
registration is separate. Which mode is enabled for a particular ladder has
not been verified by our accepted API read. No upload, new-character
registration, journal/provenance API, deletion or offline-character import is
implemented here. The existing offline save path remains separate.

An independent D2SSharp 0.0.22 reader/writer (the dependency pinned by Reimagined Launcher v0.19.7) round-tripped the two local backup samples, character and shared stash, byte-identically. This held with embedded vanilla tables and with both primary/base text-table datasets extracted and hashed from the signed revision-4 ladder package. This is two-sample offline format evidence, not a server save receipt or a claim about all modded items. The .NET tool is a Mac development reference, not part of the native iOS game.
