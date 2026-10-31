# Original-engine D2S completion boundary

`dm/host/hle_fs.c` exposes the optional `dm_save_completion.h` native receiver. Its weak defaults are disabled/no-op. A coordinator overrides both functions and enables the receiver only while its explicit isolated server-save scope is bound. No production receiver/coordinator is connected yet.

The close event is emitted after the actual successful POSIX close of a D2S handle opened for writing. A borrowed canonical host path is obtained before close and is valid only during the callback. Read-only D2S closes do not emit events. Rename events occur only after a successful rename to D2S and guest-name metadata update.

A failed close does not advance the completed-D2S sequence or emit an event. On a transactional save mount it poisons the transaction, preserving the previously committed save through the existing rollback path. A successful close after an earlier poisoned writer operation also emits no completion event. The existing sequence remains an IO-order marker, not a serialization order or a server acknowledgement.

The callback may run on an engine IO thread. It must copy the borrowed path, filter its separately verified server namespace, match complete D2S bytes to received metadata and keep sidecar publication inside the same working-directory commit transaction. It must not auto-import arbitrary offline completions. The five existing pre-commit hooks are retained.

Independent IO producers may deliver callbacks out of order. The shared completed-write marker uses an atomic maximum so a late producer cannot move it backward. This does not order serialization or freeze the file at that path; matching actual complete bytes and the active namespace/generation remains mandatory.

```sh
make -C dm/host/tests save-completion
```

The focused test uses the real host filesystem, checks that the descriptor is already closed and bytes readable when the callback runs, verifies writer/rename selection, rejects failed events and confirms rollback keeps the previous committed bytes. Existing filesystem and filename regressions remain separate.

An event alone does not prove checksum validity, commit success, accepted server progress or ladder admission. Native transport, metadata matching and the full save coordinator remain unfinished.

An isolated original ARM64 Mac run exercised the hook through the game's own Save and Exit path. It observed a1039-byte version105 file with a valid rolling checksum; an independent read of the committed disposable save copy matched the observed digest, and the game returned to its front end. The original source fixture stayed unchanged. This was offline engine-boundary evidence, with no production receiver, server upload or iPhone update.
