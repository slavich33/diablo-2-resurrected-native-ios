# Native sidecar history updates

`CharacterSidecarHistory.swift` implements initial-history creation and advancement of the original v2 history fields. It does not select a save namespace, import an offline character, publish a file or obtain a server receipt.

The16 bytes at payload48..<64 identify the history. They are not a character name. Starting a new history uses native OS randomness by default, sets both timestamps to the selected time, count1 and a zero predecessor digest. A caller may explicitly mark a restart/discontinuity; an unreadable prior file never triggers this operation automatically.

Advancement keeps the previous identifier and creation time, sets the new update time, increments the counter and stores SHA256 of the **exact previous complete sidecar file**, including its header. It does not substitute a re-encoded file. Clock rollback sets the original discontinuity bit. Original contract words are folded with OR, saturating count addition, earliest nonzero first value and maximum last value; their wider gameplay meanings remain unassigned.

Timestamps are Unix whole seconds, clamped to1 below2. The original import is MSVCP140 `_Xtime_get_ticks`; its signed100ns-to-seconds conversion matches the native helper, including negative/zero/boundary values. Microsoft's implementation subtracts the Windows-to-Unix epoch before returning ticks: [STL xtime.cpp](https://github.com/microsoft/STL/blob/main/stl/src/xtime.cpp).

## Keys and predecessor trust

The public advancement API verifies a signed predecessor against the caller's own trusted P-256 key before changing history. A different key or corrupt signature fails explicitly. The original protocol also permits an unsealed predecessor: the native API supports that route only with an exact digest supplied from a separately authenticated server-snapshot manifest. Computing a digest from an arbitrary local file does not establish that provenance; the game coordinator must enforce it.

The new current candidate must be unsealed, prepared from the matching completed save and gameplay environment. History preparation clears old seal fields; native CryptoKit then signs the resulting complete payload. Signed prior content is never silently edited/re-signed.

The original helper resets history after an exhausted counter. The native advancement API reports exhaustion so the coordinator can make the explicit reset decision using the authenticated namespace/snapshot and original policy; it never wraps the counter or silently invents continuity. Reset/foreign-key migration policy remains part of the unfinished coordinator.

## Independent reference

`verify_sidecar_history.py` runs the full original history merge, file decoding/encoding and previous-file SHA256 on143 own synthetic cases. OS clock/RNG and sign/verify callbacks use declared deterministic fixtures, so this reference proves the history algorithm rather than those callbacks' cryptography. Native signing has separate original-digest/OpenSSL verification.

Cases cover initial flags, signed/unsealed predecessors, negative/subsecond/large clock values, rollback, contract overlap and count saturation, variable old-file records and exhausted-counter policy. Swift checks the projected fields against every case and separately exercises genuine native signatures, pinned-key rejection, explicit unsigned-snapshot digest, malformed prior files and counter exhaustion.

```sh
python dm/online/tools/verify_sidecar_history.py --dll /path/to/your/D2RCore.dll
swift test --package-path dm/online
```

The [commit-session API](CHARACTER_SAVE_COMMIT_SESSION.md) now composes completed-file metadata matching, environment projection and signing/history. The dedicated filesystem gate preserves the existing directory transaction. Their production receiver, authenticated namespace/table leases and server acceptance/reload remain unconnected. This component does not establish ladder admission or accepted progress.
