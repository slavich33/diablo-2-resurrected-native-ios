# D2EM environment description

`EnvironmentDescription` implements required fields1..6 of the D2EM-v3 envelope. The contract was independently checked against the pinned official D2RLoader 1.3.1-beta core, SHA256 `2a868d013d2e0830bd2d9e04b918b19e46a73cf726c833e70d089b948fdeb5a2`. A fresh official archive download on 31 October 2026 contained that same core. No original executable bytes or game data are distributed.

All multibyte integers are little-endian. Coverage is complete1, partial2 or unavailable3. Digests are32 bytes with a preceding u8 length0/32; unavailable data has no digest. The parser fully consumes each required payload, validates canonical tags and rejects contradictory availability/counts. Required fields must be marked required in the outer envelope.

| Field | Payload |
| --- | --- |
|1|version:u16, sidecarCapability:u32, sidecarFormat:u16, word8:u16, word10:u32|
|2|aggregate rollup: policyVersion:u16, coverage:u8, componentCount:u32, digest|
|3|literal count7:u8, then tagged rollups in tag order1..7|
|4|literal count3:u8, then tag:u8, policyVersion:u16, coverage:u8, digest in tag order1..3|
|5|literal count3:u8, then tag:u8, policyVersion:u16, coverage:u8, valueLength:u8=0/8, optional value:u64 in tag order1..3|
|6|count:u16<=256, then tag:u8, flags:u8, nameLength:u16<=1024, name bytes, digest32|

Contract version/word8/word10 and policy versions must be nonzero. Sidecar capability is0/1, with format0 exactly when capability0. Field6 names/flags and the two opaque contract words are not given unverified gameplay meanings. The required-field corpus deliberately has an empty named inventory; its full validity and ordering are not established.

A rollup's unavailable state requires count0/no digest; partial requires a positive count/digest. A complete group may be empty without a digest. The aggregate count equals the sum of all seven groups without u32 overflow. Its coverage is complete if all groups are complete, otherwise unavailable when the total is0, otherwise partial. A complete aggregate must contain at least one component. Bank/schema availability similarly requires its digest/value. These are known local consistency rules, not proof that hashes represent actual game resources.

`unavailableProfile()` produces166 bytes and advertises no known fingerprints, banks, schemas, named records, plugins or sidecar capability. Contract words2/0/0/4/7 and policy versions4/4/2 match independently addressed original decoder defaults. Native struct layout has padding and is not the packed wire layout. The actual Swift output SHA256 is `93e5cb7b60a0dde292f70ad16fcec2fd9f4957440282f14647d66bc6330cea33`; it matched independent encoding and the full original parser/local validator. It remains an unsupported gameplay profile.

## Native loaded ItemStatCost schema

`ItemStatCostSnapshot.environmentSchema()` calculates policy2's full-table value from copied ARM64 rows and their actual resolved names. This is independent of the smaller set of descriptors used by a selected save. The full original schema builder/name-cache lookup/hash matched67 synthetic cases across all three editions, row counts, relevant columns, irrelevant-column mutations, name lengths/UTF8 and name order. Native Swift and that original algorithm also match on a stored native engine capture of368 rows and368 names. The capture is private development evidence and is not distributed.

The value is FNV-1a64 over little-endian row count:u32, followed by each row in numeric-ID order: ID:u32, UTF8 name byte count:u32, name bytes, Save Add:u32, Save Param Bits:u32, Save Bits:u8, ValShift:u8, CSvBits:u8, CSvParam:u8, CSvSigned:u8 and row-present:u8. Each copied native row is present. A missing resolved name throws instead of substituting another edition's name or claiming a partial table is complete. Native columns and the324-byte stride are separately checked against the exact ARM64 initializer.

The iOS `NativeEnvironmentTableProfile.capture()` reads full names/rows through the real C capture API. Unloaded, failed or nameless binary-table captures remain unavailable; only a complete named capture supplies a known schema and its generation. The ordinary diagnostic helper keeps sidecar support0. `capturePreparedPeerProfile()` first requires an isolated server namespace and uses the linked native sidecar-v2 profile. Both keep aggregate/groups, banks and named fingerprints unavailable/empty; only the actually captured table schemas become known. It does not copy a Windows/host fingerprint or infer mod compatibility from a matching schema.

Capture requires a quiescent engine. `validateCurrent()` rejects changed generations, table availability, row/name counts, including a previously unloaded edition becoming loaded. This check does not freeze engine execution or establish admission. The original `-txt` load produced names in the bounded development capture; ordinary binary-table loading did not. This change does not enable `-txt` in product startup or activate the app's missing game coordinator.

A later native text-load with a signed mod package captured444 rows and444 names. Its numeric schema columns matched the source table, but ten names were lowercased by the native linker, producing a different full-table value from the previously received host profile. The source observations now bind original spelling to that actual loader invocation and validate it against the complete native linker. A fresh native run retained all444 exact source names without changing any game row; both the full original schema builder and native Swift then matched the previously received host schema. This establishes table-schema parity only, not world entry, other table-bank compatibility or a server progress-save round trip. A host value must never replace a mismatching native value.

The build-time CASC overlay tool now resolves entries through actual TVFS paths, updates both container and virtual-file lengths, and interprets encoding-spec references as byte offsets in EST. Treating those offsets as string ordinals incorrectly wrapped a raw text resource in BLTE and stopped the native table loader. The regression tests use small owned archives: `python3 dm/tools/test_casc_overlay.py`. Neither the signed mod resources nor native table exports are public fixtures.

```sh
python dm/online/tools/verify_itemstatcost_environment.py \
  --dll /path/to/your/D2RCore.dll --main /path/to/your/ExeFS/main
```

The reference executes only the original schema builder/hash with private synthetic table resources and uncontended lock stand-ins; no original OS, DLL/game entry point or network operation runs. Optional `--captured-rows`/`--captured-names` verify a separately owned private C diagnostic export without writing it or including it in the synthetic corpus. The coupled native C/Swift filesystem tool also checks missing names, edition availability, field5 roundtrip and rejection after a real capture-generation reload.

## Optional metadata and sidecar projection

`EnvironmentMetadata` implements known optional fields16..18, which must not carry the required flag. Each text has a u16 byte length<=1024. The environment codec preserves raw byte strings; it does not silently convert invalid UTF8 or embedded NUL into a different identity.

| Field | Payload |
| --- | --- |
|16|two texts|
|17|four texts, opaque word:u32, flag:u8=0/1; first text must be nonempty|
|18|count:u16<=256, then four texts, role:u8=1/2, scope:u8=1/2/3, two opaque u32 words, digestLength:u8=0/32 and digest|

A plugin's first and fourth texts must be nonempty. Identity is the pair role/first-text, irrespective of scope. The full original parser requires records already in ascending role and unsigned lexicographic first-text order; duplicate identities and noncanonical order are rejected. Absence of a field remains distinct from an explicitly empty record. Unknown optional fields remain unchanged in `EnvironmentDescription.optionalFields`.

`CharacterSidecar(fixedFields:environmentMetadata:clientPlugins:stats:)` projects the two root texts, inserts an empty third text into the mod's five-text sidecar record and copies its word/boolean into word/scope. It uses only environment plugins with scope2/3, then appends the caller's explicitly supplied actual client scope1 records. Host scope1 plugins are never relabeled as client counterparts. The mod-present word is set before the existing sidecar validator checks all text, record-count and duplicate constraints. Sidecar UTF8/NUL/required-text rules are stricter than the environment's byte-string rules; an unsupported projection throws instead of losing information. Apply projection before history/signing.

This mapping follows the pinned original D2S completion wrapper; the whole Windows filesystem wrapper was not executed. The native projection tests cover scope separation, mod/text placement, absent fields, codec round trip, own-key signing and stricter-text refusal. This metadata API does not authenticate a host profile, obtain native fingerprints, select a server namespace, commit files or upload progress. The linked local save receiver is tested separately; the actual app/network coordinator remains disconnected. The explicit native-codec profile below describes format support independently of game admission.

## Reproduce

`Fixtures/required-environment-reference.json` contains276 synthetic cases with24 accepted by the complete original parser and local validator. It covers all required-field truncations, missing/trailing fields, sidecar contradictions, aggregate/group coverage and counts, policies, canonical tags and bank/schema lengths. The Swift test suite replays every case without any original binary. Accepted canonical envelopes also re-encode byte-exactly.

`Fixtures/environment-metadata-reference.json` additionally checks the complete original parser/local validator on232 synthetic cases, with84 accepted, including decoded native-model bytes, all short-record truncations, text limits/raw bytes, flags, role/scope, digests, duplicate identities and canonical ordering. Native Swift must match acceptance, decoded fields and exact re-encoding for every accepted input. No original model or game bytes are shipped.

For an independent original-code reference, use your own exact core and a separate development Python environment with Unicorn 2.1.4:

```sh
python dm/online/tools/verify_environment_description.py --dll /path/to/your/D2RCore.dll
python dm/online/tools/verify_environment_metadata.py --dll /path/to/your/D2RCore.dll
xcrun --sdk macosx swiftc -parse-as-library -O -module-name RequiredEnvironmentCheck \
  dm/online/Sources/ReimaginedClient/{EnvironmentEnvelope,EnvironmentDescription,EnvironmentMetadata}.swift \
  dm/online/tools/verify_environment_description.swift -o /private/scratch/verify-environment
/private/scratch/verify-environment dm/online/Tests/ReimaginedClientTests/Fixtures/required-environment-reference.json
```

The reference pins the whole core, bounds instructions/memory/copies and substitutes only private-arena allocation/copy/free/memcmp. It executes no DLL entry point, OS API, game or network operation. It requires Python assertions enabled. A new synthetic corpus may be written with `--output` to a previously nonexistent path; existing files are never overwritten. The shipped iOS code uses native Swift/C/ARM64, not this development reference.

## Linked native sidecar support

`EnvironmentDescription.nativeSidecarCodecProfile()` is an explicit profile for programs linking this library's sidecar codec. It declares support1 and the codec's actual `CharacterSidecar.formatVersion`2, with unavailable data, empty named inventory and no copied host/plugin metadata. `unavailableProfile()` retains support0. These words describe the supported sidecar format; they are not an admitted engine, loaded mod, signing-key ownership, active filesystem binding or confirmed server save.

The pinned original profile constructor at38f7f0 writes format2 and support1 unconditionally at38fe6b/38fe74 before peer admission. The public environment reference now executes only those two stores, checks the result and validates the corresponding full envelope with the original parser. It makes no OS/game/network call. This corrects the earlier assumption that support had to remain0 until world entry or every bank fingerprint was implemented.

The iOS peer profile helper additionally requires the pre-boot isolated namespace. Its linked local save receiver, metadata/seals/history, table leases and transaction checks remain separate from the server handshake. No app Join button or engine activation is created by constructing a profile.

## Live boundary

The earlier bounded native Mac check reached refusal22 after an all-unavailable support0 profile (server1/client0). On1 November2026 the signed native Mac helper refreshed its authorized session, fetched policy revision8, verified all3814 files and the signed manifest using the previously trusted key, checked policy again, obtained a matching ticket/narrow token and resolved one public room.

It sent only its166-byte native-codec profile through a195-byte kind7 carrier. The real peer returned its6599-byte typed D2EM profile in31 ordered fragments and a zero-payload kind8 marker, with no kind9 refusal. All required fields and known optional metadata decoded. The client sent no character bytes, game commands or save writes, closed the socket and received token-revocation acceptance. The private response is retained without publishing server metadata/resources or credentials.

This proves a real environment-description exchange past the previous support mismatch. Kind8 is still not world entry, complete client/host compatibility, account/character game authentication or a saved-progress receipt. Native remote-role startup, packet/transport integration, selected server character and actual gameplay/reconnect/server-save readback remain required.
