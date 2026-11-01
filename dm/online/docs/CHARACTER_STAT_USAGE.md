# Character stat usage and sidecar descriptors

The two version7 character-metadata blobs are stat-ID bitmaps. Original exported wrappers `WriteItemSaveStatId` and `WritePlayerSaveStatId`, their serializer capture and descriptor builder independently establish the ordering: `blob71` is item stats and `blob1071` is player stats. Each bitmap represents IDs0..32767, little-endian within each byte. The original metadata sender trims trailing zero bytes; repeating an ID sets the same bit.

`CharacterStatUsage` decodes/constructs these sets and maps them to sidecar flags: item2, player1, both3. It lists the union in ascending ID order, matching the inspected serializer loop. This describes listed usage only; the separate opaque metadata flag/history words do not become a proof of completeness or authority.

`ItemStatCostSnapshot` accepts immutable copied324-byte rows from the selected edition1..3 and already-resolved stat names. Used rows must exist, and their names must be nonempty UTF8, at most1024 bytes and NUL-free. Any missing used row/name throws instead of returning a partially rebuilt descriptor list. `descriptors(for: metadata)` also requires the metadata's edition to match. The snapshot itself does not locate a live table, load a mod, resolve name fallbacks or prove the table's active environment/fingerprint.

## Independently checked layout

The exact original ARM64 `3.3.94012` table-descriptor initializer was run for editions1..3, stopping before its first external call. It produced the same column layout in each edition. Its original table-load call separately specifies row stride0x144 (324). The original Windows descriptor builder reads these same fields from supplied synthetic table rows and the original name cache.

| ItemStatCost column | Row offset | Sidecar field when used |
| --- | --- | --- |
|save bits|0x15:u8|item `byte34`|
|valshift|0x14:u8|item `byte35`|
|save add|0x18:u32 bit pattern|item `word2c`|
|save param bits|0x20:u32|item `word30`|
|csvbits|0x0a:u8|player `byte38`|
|csvparam|0x0b:u8|player `byte39`|
|csvsigned|bit12 of u32 at0x04|player boolean|

Absent-role fields are zeroed, matching the original builder. Save Add retains its exact32-bit representation, including negative signed representations; no numeric conversion changes its bits. The fixed sidecar block and unrelated metadata words remain opaque.

The row layout is shared; the table-manager headers are different. Native manager pointer/count are at+0x1290/+0x1298, whereas the reference Windows resource callback supplies+0x1258/+0x1260. The portable Swift snapshot accepts copied rows and does not dereference either live header or assume they are interchangeable.

## Native loaded-table capture

The optional `DM_NET_TABLE_CAPTURE=1` rewrite adds read-only observations at the checked loader entry, raw text input and normal epilogue of the exact ARM64 ItemStatCost loader. `hle_net_tables.c` copies the finished rows synchronously, identifies the edition by the engine's manager slots and publishes owned bytes under a generation. A query/copy that crosses a reload returns `STALE`; a failed row reload invalidates the previous snapshot. The game never receives a pointer to this copy, and callers never retain its live table pointer.

The native name-linker pointer is at manager+0x12a8. It is not manager+0x1a8. The original native lookup/destructor ground its bucket and node layouts. The bounded capture rejects unreadable pointers, cycles, duplicate/out-of-range IDs, excessive strings and inconsistent counts. A missing/empty linker keeps row capture available but exposes no names; it never supplies a base-game name list as a substitute. Swift also rejects invalid UTF8.

The linker lowercases ASCII names. To preserve the source spelling used by the wire schema, the raw-text observer accepts only the checked ItemStatCost caller and its saved table manager. It copies bounded `Stat`/`*ID` (or `ID`) fields from the actual bytes about to enter the native parser. The completed capture requires ordered IDs, the same manager, a complete native linker and agreement of every name under ASCII case folding before taking those original spellings. Loader entry clears pending state; thread-local ownership and a load epoch reject stale/cross-thread source reuse. Invalid or incomplete source binding exposes no names. Binary loads and older observation builds retain their actual linker behavior. Game rows and game strings are never changed.

`NativeItemStatCostCapture` in the iOS sources queries the C API, copies only the used IDs' names under the same generation, builds the portable snapshot and exposes `validateCurrent()` for a later save-transaction commit. This helper is not yet called by a completed-save coordinator and does not enable sidecar capability or network admission.

On 2026-11-01 an isolated original ARM64 Mac run captured368 rows. A second run using the game's `-txt` path captured all368 names; its rows matched the binary-loaded rows byte for byte. All1104 item/player/both descriptor cases from that private runtime capture matched the full original Core descriptor builder. The default binary-table path had an empty linker, so it cannot currently supply a complete named snapshot by itself. No iPhone installation, live game admission or server progress-save round trip was performed by this check. Captured game data stays outside the repository.

Optional diagnostic export requires an explicit `DM_NET_TABLE_CAPTURE_DIR` pointing to a private directory. It writes copied game rows/names with mode0600; these are game resources and must not become public fixtures. Normal capture performs no filesystem write without that variable.

## Reproduce

The original descriptor builder/name lookup matched204 synthetic cases:201 descriptors and3 missing-resource failures. The frozen corpus contains only synthetic rows, names, expected descriptors and original input identities. It exercises editions, bit/byte boundaries through ID32767, item/player roles, signedness, opaque word/byte extremes and UTF8/SSO-name boundaries. Swift tests additionally cover all32768 item IDs, duplicate capture, canonical zero tails, missing schemas and wrong editions.

```sh
python dm/online/tools/verify_native_itemstatcost_schema.py /path/to/your/original/ExeFS/main
python dm/online/tools/verify_character_stat_descriptors.py \
  --dll /path/to/your/D2RCore.dll --main /path/to/your/original/ExeFS/main
swift test --package-path dm/online
make -C dm/host/tests net-tables
bash dm/online/tests/NativeTransportABI/tables.sh
```

The tools pin the entire original inputs. Native descriptor initialization runs with only private stack/manager fixtures and invokes no external function. The Windows reference supplies an immutable synthetic GetTables resource and generic private-arena memory/uncontended locks; its name lookup and descriptor-building code remain intact. No DLL entry point, game startup, OS API, network, save or original data table is used. Python assertions must be enabled; `--output` creates a new mode0600 synthetic corpus without overwriting files.

See [CHARACTER_METADATA.md](CHARACTER_METADATA.md) and [CHARACTER_SIDECAR.md](CHARACTER_SIDECAR.md). Runtime table capture, genuine environment/history/seal conversion and the engine's D2S completion/commit integration remain unfinished. This does not change the advertised sidecar capability or enable ladder admission.
