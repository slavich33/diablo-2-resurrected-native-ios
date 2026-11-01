import Foundation

extension EnvironmentDescription {
    /// This linked native library implements the sidecar v2 codec. The original
    /// profile constructor advertises support1/format2 before peer admission.
    /// Data is still unavailable here: no host fingerprints, plugins, admitted
    /// engine, selected character or server-save authority is inferred.
    public static func nativeSidecarCodecProfile() throws -> EnvironmentDescription {
        let base = try unavailableProfile()
        return try EnvironmentDescription(
            contract: EnvironmentContract(version: base.contract.version, sidecarCapability: 1,
                sidecarFormat: CharacterSidecar.formatVersion, word8: base.contract.word8, word10: base.contract.word10),
            aggregate: base.aggregate, groups: base.groups, banks: base.banks,
            itemStatSchemas: base.itemStatSchemas, namedFingerprints: [])
    }
}

extension CharacterSidecar {
    /// Project known environment records before history/sealing. The caller
    /// supplies its actual client-only counterparts separately; host scope1
    /// records must never be copied as the client's own plugin inventory.
    /// This does not validate fingerprints, admission or metadata provenance.
    public init(fixedFields: Data, environmentMetadata: EnvironmentMetadata,
                clientPlugins: [Plugin], stats: [Stat]) throws {
        guard fixedFields.count == 296 else { throw CharacterSidecarError.fixedFields }
        guard clientPlugins.allSatisfy({ $0.words.count == 4 && $0.words[1] == 1 }) else {
            throw CharacterSidecarError.plugin
        }
        var fixed = Data(fixedFields)
        fixed.replaceSubrange(0..<4, with: [environmentMetadata.mod == nil ? 0 : 1, 0, 0, 0])
        let mod = environmentMetadata.mod.map {
            Mod(scope: $0.flag ? 1 : 0, word: $0.word,
                texts: [$0.texts[0], $0.texts[1], Data(), $0.texts[2], $0.texts[3]])
        }
        let remotePlugins = (environmentMetadata.plugins ?? []).filter { $0.scope != 1 }.map {
            Plugin(words: [UInt32($0.role), UInt32($0.scope), $0.word84, $0.word88],
                hasDigest: $0.digest != nil, digest: $0.digest ?? Data(count: 32), texts: $0.texts)
        }
        try self.init(fixedFields: fixed, texts: environmentMetadata.rootTexts ?? [Data(), Data()],
                      mod: mod, plugins: remotePlugins + clientPlugins, stats: stats)
    }
}
