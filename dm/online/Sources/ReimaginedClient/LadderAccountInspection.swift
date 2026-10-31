import Foundation

public enum LadderInspectionError: Error, Equatable {
    case gameTokenUnavailable, tokenRevocationFailed
}

public struct LadderAccountInspection {
    public let saves: ServerSaveManifest
    public let lobby: LobbyGameList
}

extension ReimaginedAPIClient {
    /// Read-only game/save API inspection after complete package validation.
    /// The short-lived token stays in memory and is revoked before return.
    /// No character upload, engine activation, socket or admission is implied.
    public func inspectLadderAccount(bundle: LadderBundleDescriptor,
                                     verifiedPackage: VerifiedLadderPackage,
                                     session: LauncherSession) async throws -> LadderAccountInspection {
        let ticket = try await launchTicket(ladderID: bundle.ladderId, bundle: bundle,
                                            verifiedPackage: verifiedPackage, session: session)
        guard let token = try await createGameToken(session: session) else {
            throw LadderInspectionError.gameTokenUnavailable
        }
        let result: Result<LadderAccountInspection, Error>
        do {
            try Task.checkCancellation()
            let saves = try await serverSaveManifest(ladderID: bundle.ladderId, gameToken: token, ticket: ticket)
            try Task.checkCancellation()
            let lobby = try await lobbyGames(ladderID: bundle.ladderId, gameToken: token, ticket: ticket)
            result = .success(LadderAccountInspection(saves: saves, lobby: lobby))
        } catch { result = .failure(error) }
        // Cleanup also runs when a read is refused. No launcher-token fallback,
        // saved token file or automatic retry of a refused request is used.
        let cleanup = Task { try await self.revokeGameToken(token) }
        do { try await cleanup.value }
        catch { throw LadderInspectionError.tokenRevocationFailed }
        return try result.get()
    }
}
