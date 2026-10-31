import Foundation

extension CharacterSidecar {
    // The exported original D2S-completion wrapper copies metadata's checksum,
    // byte count and whole-file digest into these fields. In particular, the
    // word at wire offset12 is a byte count, not the game's save version.
    public var saveChecksum: UInt32 { saveWord(at: 8) }
    public var saveByteCount: UInt32 { saveWord(at: 12) }
    public var saveSHA256: Data { fixedFields.subdata(in: 16..<48) }

    private func saveWord(at offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(fixedFields[offset + $1]) << (8 * $1) }
    }

    /// Check an already-complete version105 file against this signed sidecar
    /// and a separately trusted public key. Name must come from the selected
    /// isolated server-character record, never an arbitrary local save path.
    /// This proves local integrity/key continuity, not a server save receipt.
    public func verifySignedVersion105Save(_ data: Data, expectedCharacterName: String,
                                          expectedPublicKey: Data) throws {
        try verifySeal(expectedPublicKey: expectedPublicKey)
        guard data.count >= 403 else { throw CharacterSaveMetadataError.saveMismatch }
        // Reuse the port's verified version105 header/name/rolling-checksum
        // preflight. Edition is itself bound by the complete-file SHA256.
        let identity = try CharacterSaveMetadata(characterName: Data(expectedCharacterName.utf8),
            saveChecksum: saveChecksum, saveByteCount: saveByteCount, gameEdition: data[data.startIndex + 248],
            saveSHA256: saveSHA256, word50: 0, word58: 0, word60: 0, word68: 0,
            flag70: false, blob71: Data(), blob1071: Data())
        try identity.verifyVersion105Save(data, expectedCharacterName: expectedCharacterName)
    }
}
