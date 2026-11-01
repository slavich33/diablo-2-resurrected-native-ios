# Original-engine D2S completion boundary

`dm/host/hle_fs.c` exposes the optional `dm_save_completion.h` native receiver. Its weak defaults are disabled/no-op. [NativeSaveCommitCoordinator](NATIVE_SAVE_RECEIVER.md) supplies linked Swift overrides whose registry starts empty. The app's actual online startup does not yet bind it or start an admitted engine session.

The close event is emitted after the actual successful POSIX close of a D2S handle opened for writing. A borrowed canonical host path is obtained before close and is valid only during the callback. Read-only D2S closes do not emit events. Rename events occur only after a successful rename to D2S and guest-name metadata update.

A failed close does not advance the completed-D2S sequence or emit an event. On a transactional save mount it poisons the transaction, preserving the previously committed save through the existing rollback path. A successful close after an earlier poisoned writer operation also emits no completion event. The existing sequence remains an IO-order marker, not a serialization order or a server acknowledgement.

The callback may run on an engine IO thread. It must copy the borrowed path, filter its separately verified server namespace, match complete D2S bytes to received metadata and keep sidecar publication inside the same working-directory commit transaction. It must not auto-import arbitrary offline completions. The five existing pre-commit hooks are retained.

## Final commit gate

`dm_online_save_prepare(workdir,commitdir)` runs after all five legacy pre-commit hooks and before cloning the work tree. Its weak default returns0. A linked coordinator may prepare a matching signed sidecar in the same work directory while holding its authenticated namespace/table leases. It must not wait on network or call game filesystem APIs: path/mount locks are held.

HLE write, resize and close use that same path lock. When a receiver is bound, Commit defers before entering prepare if any save writer remains open. A completed close is thus not used to justify publishing another still-open file.

A nonzero return defers the commit, preserves both the complete pending work tree and previously committed tree, and sends the existing save-error notification. Missing metadata must not poison a valid work tree and discard progress. An already poisoned writer transaction follows its existing rollback path without entering this gate. If the gate itself poisons the transaction while returning0, that rollback still runs.

`dm_online_save_finished(workdir,commitdir,committed)` is called exactly once for every prepare on the same thread, including a refused prepare, poisoned rollback, failed clone or failed swap. A successful result follows the actual directory swap. Release the coordinator's lease here before the independent post-commit observer. This is local atomicity, not server acceptance. The production defaults remain no-op until an explicitly bound receiver exists.

```sh
make -C dm/host/tests save-commit-gate
```

The real filesystem test retains all five legacy hooks, checks deferral/retry without discarded work, injected clone/swap failures, paired publication and balanced completion calls. Its mock sidecar contains synthetic marker bytes rather than a signature; native signing and metadata/history state have separate [commit-session tests](CHARACTER_SAVE_COMMIT_SESSION.md).

Independent IO producers may deliver callbacks out of order. The shared completed-write marker uses an atomic maximum so a late producer cannot move it backward. This does not order serialization or freeze the file at that path; matching actual complete bytes and the active namespace/generation remains mandatory.

```sh
make -C dm/host/tests save-completion
```

The focused test uses the real host filesystem, checks that the descriptor is already closed and bytes readable when the callback runs, verifies writer/rename selection, rejects failed events and confirms rollback keeps the previous committed bytes. Existing filesystem and filename regressions remain separate.

An event alone does not prove checksum validity, commit success, accepted server progress or ladder admission. The [commit-session API](CHARACTER_SAVE_COMMIT_SESSION.md) and receiver now have a coupled native local verification; actual app/namespace startup, admission and network/server-save integration remain disconnected.

An isolated original ARM64 Mac run exercised the hook through the game's own Save and Exit path. It observed a1039-byte version105 file with a valid rolling checksum; an independent read of the committed disposable save copy matched the observed digest, and the game returned to its front end. The original source fixture stayed unchanged. This was offline engine-boundary evidence, with no production receiver, server upload or iPhone update.
