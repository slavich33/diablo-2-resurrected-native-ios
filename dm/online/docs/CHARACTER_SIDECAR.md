# Version-2 character sidecar files

`CharacterSidecar` independently implements the complete version-2 file container, fixed block, optional mod record, plugin records and stat-description records. It preserves opaque fields without claiming their gameplay meaning. Decoding a file verifies structure, known local consistency rules and SHA256; it does not authenticate a history/seal, grant ownership or enable game admission.

## File and payload

The header is 44 bytes: ASCII `D2RL`, version:u16=2, headerSize:u16=44, payloadSize:u32<=2097152 and SHA256(payload):32. Integers are little-endian. Total length must equal 44+payloadSize. Version1 is outside this native codec; it is refused rather than converted implicitly. This is a file header, separately from the version1 D2RL network envelope.

The payload contains a 296-byte fixed block, two length-prefixed UTF8 strings, optional mod information selected by its first u32, a u32 plugin count with 0..256 records, then a u32 stat count with 0..32768 records. Strings have u32 byte length<=1024, valid UTF8 and no NUL. Required strings must be nonempty. The decoder consumes the complete payload, rejects duplicate plugin identities/stat IDs and bounds its total allocation. Fixed-block reserved words and the known availability, counter, mask and opaque seal-field consistency rules follow the original validator. Their actual authority and signature semantics remain separate.

A mod record preserves two u32 words (the first 0/1) and five strings, with the first two required. A plugin preserves four u32 words, digest-present:u32=0/1, reserved:u32=0, digest32 and four strings (first required). Its first two words have bounds 1..2 and 1..3. A false digest-present flag requires a zero digest. Duplicate identity is the first two words and exact first string, preserving case. A true flag does not by itself establish valid digest provenance.

A stat record preserves id:u32<=32767, flags:u8=1..3, boolean:u8=0/1, two opaque bytes, two u32 words, two further opaque bytes, reserved:u16=0 and a required name. The flags constrain absent subfields to zero. These are wire/model fields, not permission to introduce or change a game's stats. IDs must be unique in the file.

The API keeps its fixed block and unassigned record words opaque. No filesystem path is derived from text in a sidecar. No method reads a character, changes a save mount, publishes a sidecar or uploads progress. The memory limits are local parsing limits; native history/seal capture and completed-D2S association still need integration.

## Original-code reference

The independently pinned official core is SHA256 `2a868d013d2e0830bd2d9e04b918b19e46a73cf726c833e70d089b948fdeb5a2`. Its complete version2 reader, local consistency validator, writer and original SHA256 implementation matched 1077 synthetic cases, with 93 accepted. Every accepted case matches the native Swift writer's canonical bytes. Cases cover baseline truncation at every byte, file-header/digest damage, fixed-block constraints, lineage/seal-field shape, UTF8/length boundaries, mod/plugin/stat records, duplicate identities and opaque-value preservation.

The original SHA256 helper was independently checked against SHA256(`abc`), then left intact for all corpus reader/writer calls. The reference substitutes only generic private-arena stack probing, allocation, copy/fill/compare/free and vector append. It runs no DLL entry point, OS API, game, network or original save. Instructions, time, memory and copies remain bounded; Python assertions must be enabled. Cryptographic seal authentication is not modeled or claimed.

`Fixtures/character-sidecar-reference.json` contains only synthetic input/canonical output and source identity. The Swift suite replays it without any original binary. Reproduce the original reference with your exact owned core and a separate desktop Python environment with Unicorn 2.1.4:

```sh
python dm/online/tools/verify_character_sidecar.py --dll /path/to/your/D2RCore.dll
swift test --package-path dm/online
```

`--output` creates a new mode0600 synthetic corpus and never overwrites an existing file. Game resources, executables, characters, credentials and original sidecars are not included. The product code is native Swift/C/ARM64; the bounded reference is development tooling.

## Integration boundary

The network metadata body is separately documented in [CHARACTER_METADATA.md](CHARACTER_METADATA.md). Converting genuine received metadata plus a verified gameplay environment into this file, verifying/preserving its authoritative history/seal, and committing it at the correct original-engine D2S completion point remain unfinished. The actual startup/room mapping, environment fingerprints/plugin counterparts and admission/gameplay/save coordinator remain incomplete too. The native profile continues to advertise sidecar capability 0; this codec alone is not advertised as complete support. No iPhone update or live admission/save test was performed for this change.
