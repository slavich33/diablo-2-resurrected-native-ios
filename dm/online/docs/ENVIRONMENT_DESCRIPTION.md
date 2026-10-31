# Required D2EM description

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

Contract version/word8/word10 and policy versions must be nonzero. Sidecar capability is0/1, with format0 exactly when capability0. Names, record flags, the two opaque contract words and optional-field semantics are not inferred from these structural checks. The corpus below deliberately has an empty named inventory; full named-record validity and ordering are not established.

A rollup's unavailable state requires count0/no digest; partial requires a positive count/digest. A complete group may be empty without a digest. The aggregate count equals the sum of all seven groups without u32 overflow. Its coverage is complete if all groups are complete, otherwise unavailable when the total is0, otherwise partial. A complete aggregate must contain at least one component. Bank/schema availability similarly requires its digest/value. These are known local consistency rules, not proof that hashes represent actual game resources.

`unavailableProfile()` produces166 bytes and advertises no known fingerprints, banks, schemas, named records, plugins or sidecar capability. Contract words2/0/0/4/7 and policy versions4/4/2 match independently addressed original decoder defaults. Native struct layout has padding and is not the packed wire layout. The actual Swift output SHA256 is `93e5cb7b60a0dde292f70ad16fcec2fd9f4957440282f14647d66bc6330cea33`; it matched independent encoding and the full original parser/local validator. It remains an unsupported gameplay profile.

## Reproduce

`Fixtures/required-environment-reference.json` contains276 synthetic cases with24 accepted by the complete original parser and local validator. It covers all required-field truncations, missing/trailing fields, sidecar contradictions, aggregate/group coverage and counts, policies, canonical tags and bank/schema lengths. The Swift test suite replays every case without any original binary. Accepted canonical envelopes also re-encode byte-exactly.

For an independent original-code reference, use your own exact core and a separate development Python environment with Unicorn 2.1.4:

```sh
python dm/online/tools/verify_environment_description.py --dll /path/to/your/D2RCore.dll
xcrun --sdk macosx swiftc -parse-as-library -O -module-name RequiredEnvironmentCheck \
  dm/online/Sources/ReimaginedClient/{EnvironmentEnvelope,EnvironmentDescription}.swift \
  dm/online/tools/verify_environment_description.swift -o /private/scratch/verify-environment
/private/scratch/verify-environment dm/online/Tests/ReimaginedClientTests/Fixtures/required-environment-reference.json
```

The reference pins the whole core, bounds instructions/memory/copies and substitutes only private-arena allocation/copy/free. It executes no DLL entry point, OS API, game or network operation. It requires Python assertions enabled. A new synthetic corpus may be written with `--output` to a previously nonexistent path; existing files are never overwritten. The shipped iOS code uses native Swift/C/ARM64, not this development reference.

## Live boundary

The bounded native Mac check reached a real server refusal code22 after sending this all-unavailable profile: sidecar capability server1/client0. See [CONTROL_PROTOCOL.md](CONTROL_PROTOCOL.md). There was no character transfer or save write. Advertising1 before implementing compatible sidecar behavior would be inaccurate. Actual fingerprint generation, plugin counterparts, full peer/admission state, gameplay transport and engine/save integration remain required; parsing required fields alone does not enable ladder play.
