# Native selected-character filesystem receiver

`NativeSaveCommitCoordinator` supplies the strong Swift implementations of the optional C completion/commit callbacks. Its registry starts empty; an ordinary offline run remains unbound. The app's online controller does not yet install it or start an admitted game session. No sidecar capability change is made by this implementation.

Construction requires a previously verified `CharacterSaveCommitSession` and a selected snapshot under exactly `LadderSaveScope.prepareDirectory(root:)`, named `snapshot-<UUID>`. It checks the selected committed D2S and optional sidecar against the session's independently supplied server snapshot. Namespaces, actual admission, native fingerprints/client plugin counterparts and signing-key scope remain caller responsibilities; this API cannot establish them from local bytes.

The coordinator retains the account/ladder parent descriptor and checks its identity on later transactions. Absolute directory components, snapshot/work roots, character folders and files are opened without following symlinks. Files are bounded regular files with one link; reads detect size/time changes. The sidecar is written through a unique exclusive0600 temporary file, fsync, successful close and same-directory rename. A failed close is never blindly retried. This uses the existing working-directory clone/swap transaction; it does not claim additional crash durability for uncommitted work.

## Transaction and generation leases

`installAdmitted` is an explicit caller action after genuine admission with the remote engine quiescent; it does not perform admission, select `DM_SAVE`, start a socket or import a character. The completion event is filtered to the selected work-file path and is only an observation marker. `receive` forwards this connection's ordered kind10 fragments. A final commit with changed bytes needs both a matching complete metadata record and a completion observation.

The final C gate holds path/mount locks. Write, resize and close now use the same path lock, and a bound commit defers while any save writer remains open. This prevents a still-open HLE writer from changing a file while the coordinator signs or clones it. All five existing pre-commit hooks remain in place.

The Swift registry and session recursive leases span prepare through finished, so metadata delivery, invalidation and coordinator replacement cannot change that transaction. A table provider must copy actual native rows/names and pin the **admitted expected generation** before returning a `SaveTableLease`. `NativeItemStatCostCapture.acquireLease(for:expectedGeneration:)` does this without using a fallback name list. A different published generation invalidates the binding instead of silently adopting another schema.

The C pin freezes publication/release of the captured snapshot, not arbitrary engine execution. No copy/name/query may be made by the pinning thread until same-thread unpin. Failed/nested pins hold nothing. The engine environment/lifecycle must independently stay bound; the pin is not a substitute for that requirement. Every prepare/finished path releases its table/session/registry leases.

Preparation independently reads the selected committed predecessor, then the final working D2S. The session produces a signed candidate and the receiver writes it beside the D2S in the same work tree. Both files are reread before clone/swap. On actual commit success it reopens the swapped committed directory and compares exact D2S/sidecar bytes again. Only that readback consumes metadata and advances local history. A post-swap mismatch sets a failure and invalidates the session even if the C filesystem returned success. `localCommitCount` is local acceptance, never a server receipt.

## Coupled native verification

```sh
python3 dm/online/tools/verify_native_save_commit.py --scratch /path/to/private/scratch
make -C dm/host/tests net-tables
```

The first command builds real host HLE filesystem/capture C together with the production Swift receiver, session, CryptoKit signing and iOS native table helper. It executes owned synthetic bytes and an ephemeral key, with no game image, account, device or network. Three progress commits have verified continuous signed history and independent committed-file readback. It also checks open-writer deferral, missing metadata, clone/swap failure, exact retry signatures, replay, selected-file and parent symlinks, an unchanged offline sentinel and rejection of a changed captured generation. A second process corrupts its own synthetic file after the directory swap; readback rejects it despite C commit success and releases the pin. These are real local C/Swift transaction checks, not real gameplay or server admission.

The capture test separately starts a concurrent reload, observes it cannot publish while pinned, then releases and verifies the new generation. It also checks wrong-thread/nested release/query rules and existing failed-capture behavior. ARM64 iOS library/helper typechecking and filesystem/capture C syntax checks are separate from a full app build/install.

## Remaining app/server integration

The actual online startup and packet pump must select the verified namespace, bind the expected capture generation, forward metadata and propagate receiver failure into the remote lifecycle. They must first isolate offline extensions and iCloud synchronization from this ladder namespace. The host retains mounted save roots and unmount is currently a no-op: changing `DM_SAVE` after an offline game has mounted is not a supported transition. The receiver must not be installed over that running offline game.

This receiver validates the selected character pair, not every file in a server snapshot. Shared stash/progress upload, whole-snapshot authorization, server expected versions/receipts, reconnect and server readback need the actual Server Saves contract. Native fingerprint acquisition, remaining protocol/engine work and real iPhone ladder play are not proved here. The advertised capability remains0 and no production binding or progress upload occurs in these tests.
