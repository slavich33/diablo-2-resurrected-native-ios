# Character save metadata transfer

`CharacterSaveMetadata` implements the version-7 body received in D2RL kind 10. It independently matches the complete original decoder and canonical sender in the pinned D2RLoader 1.3.1-beta core, SHA256 `2a868d013d2e0830bd2d9e04b918b19e46a73cf726c833e70d089b948fdeb5a2`. The original client routes kind 10 through the same bounded total/offset fragment format used by kind 7, then parses this body. This is not a sidecar file, Server Saves API receipt or proof of valid lineage/seal contents.

All multibyte values are little-endian. Names and opaque blobs remain bytes; decoding a name never turns it into a filesystem path.

| Field | Encoding / structural bounds |
| --- | --- |
|Wire version|u8=7|
|Character name|u8 count1..61, then name bytes|
|Completed D2S checksum|u32|
|Completed D2S size|u32>0|
|Game edition|u8 in1..3|
|Completed D2S SHA256|32 bytes, not all zero|
|word50|u64<=63|
|word58|u32|
|word60, word68|two u64|
|flag70|u8=0/1|
|blob71, blob1071|each u16 count<=4096, then bytes|

The unassigned word names retain original model offsets, not wire offsets. The two blob names also retain those offsets for compatibility; their bits are now independently identified as item stat IDs first, player stat IDs second. [CHARACTER_STAT_USAGE.md](CHARACTER_STAT_USAGE.md) describes native decoding and descriptor reconstruction. If word58 is 0, word50/word60/word68 must all be 0. Otherwise word50 and word60 must be positive and word68>=word60. The parser consumes the whole body; total size is 77..8329 bytes. These checks do not infer the meaning or provenance of the opaque values.

The original receiver zero-fills each fixed 4096-byte blob; its sender strips trailing zeros. Native construction/decoding uses that same canonical representation. Accepted noncanonical input may therefore re-encode shorter, which the reference corpus checks against the original sender rather than expecting a naive byte-identical input round trip.

`controlMessages()` splits the canonical body into kind 10 carriers using 1..216 data bytes, total/offset headers and the existing outer D2RL codec. `CharacterMetadataAssembly` uses a conservative ordered single-transfer policy: changed totals, out-of-order/overlapping input, incorrect kinds, oversized bodies and malformed complete metadata fail the transfer until explicit reset. The original reassembler permits matching duplicate overlap; that broader behavior is not claimed. Reset is required for a new connection/save transaction. No receiving method writes a sidecar or changes a save mount.

`verifyVersion105Save` is a separate local preflight for the port's D2S version 105. It compares expected isolated server-character name, exact byte count, magic/version/header length/checksum/edition, modern name field, complete SHA256 and the D2S rolling checksum. The current name policy is 2..15 ASCII letters and the local memory limit is 8 MiB. It does not parse quests/items, verify opaque lineage/seal data, grant server ownership or confirm accepted gameplay progress. Existing offline characters are not enumerated, imported or uploaded.

## Independent checks

The frozen corpus contains 1073 synthetic original-parser cases, 125 accepted, with the original encoder's canonical output for each accepted input. It covers every byte value for wire version/edition/boolean, all baseline truncations, name boundaries including opaque names, digest/count/contract contradictions, both blob boundaries and zero padding. Native Swift replays every accepted/rejected case and canonical output. Additional tests split complete logical carriers at every byte, retain terminal assembly failures and reject mismatched/corrupt D2S even when its SHA is updated.

Repeat the reference with your own exact core in a separate desktop environment with Unicorn 2.1.4:

```sh
python dm/online/tools/verify_character_metadata.py --dll /path/to/your/D2RCore.dll
swift test --package-path dm/online
```

The reference executes only the original bounded metadata decoder/encoder, substituting generic stack probing, allocation/copy/fill/free and vector append. It pins the whole input and invokes no DLL entry point, OS API, game, network or character file. Python assertions must remain enabled. `--output` creates a new mode0600 synthetic corpus without overwriting an existing file. The iOS product uses native Swift/C/ARM64.

## Remaining support

Native version2 file-sidecar encoding/decoding is now implemented and independently checked; see [CHARACTER_SIDECAR.md](CHARACTER_SIDECAR.md). Environment/history/seal semantics, original-engine D2S completion hooks and authenticated coordinator integration remain unfinished. This component is deliberately disconnected from sidecar-capability advertising: the current native environment profile still declares capability 0. No live kind 10 exchange, game admission or accepted server-progress save/reload is established by this corpus.
