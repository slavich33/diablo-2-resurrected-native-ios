// 默认只读；授权和游戏令牌检查须显式调用，不写角色。
// Read-only by default; authorization and game-token checks are explicit and never write characters.
import Foundation
import ReimaginedClient
#if os(macOS)
import Security
#endif

@main
struct Probe {
    // The developer probe and the signed iOS app keep independent sessions.
    private static let keychain = SessionKeychain(service: "org.d2rmobile.reimagined.probe.v1")
    static func main() async {
        #if os(macOS)
        // Process-local only: legacy Keychain reads must fail rather than
        // waiting indefinitely for UI when this ad-hoc probe is rebuilt.
        SecKeychainSetUserInteractionAllowed(false)
        #endif
        do {
            let api = try ReimaginedAPIClient()
            var session: LauncherSession?
            let args = Array(CommandLine.arguments.dropFirst())
            if args == ["--check-game-token"] {
                let store = keychain
                guard var saved = try store.load(origin: api.origin), saved.refreshExpiresAtUtc > Date() else {
                    fputs("No usable native-client session is available.\n", stderr); exit(1)
                }
                if saved.expiresAtUtc <= Date().addingTimeInterval(30) {
                    saved = try await api.refresh(saved)
                    try store.save(saved, origin: api.origin)
                }
                guard let game = try await api.createGameToken(session: saved) else {
                    print("Game-token endpoint is unavailable; launcher-token fallback is disabled."); exit(3)
                }
                print("Server issued a narrow game-session token. Token value is not logged or persisted.")
                try await api.revokeGameToken(game)
                print("Game-token revoke request accepted. No game connection or character write was attempted.")
                if game.expiresAtUtc > Date().addingTimeInterval(5) {
                    do {
                        try await api.revokeGameToken(game)
                        print("Repeat revoke was accepted; independent rejection was not established.")
                    } catch ClientError.http(401) {
                        print("Revocation verified: the server rejected the still-unexpired game token with HTTP 401.")
                    } catch {
                        print("Post-revoke authentication check was inconclusive.")
                    }
                }
                return
            } else if args.count == 2, args[0] == "--login-url-file" {
                let login = try LoopbackLogin()
                let file = URL(fileURLWithPath: args[1])
                try login.authorization.authorizationURL().absoluteString.write(to: file, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                print("Waiting for browser authorization on the random loopback port.")
                fflush(stdout)
                let callback = try await login.waitForCallback(timeout: 600)
                session = try await api.exchange(authorization: login.authorization, callback: callback)
                try keychain.save(session!, origin: api.origin)
                print("Authorized session stored in this application's local Keychain.")
            } else if args == ["--signed-schedule"] {
                session = try keychain.load(origin: api.origin)
                guard let saved = session, saved.expiresAtUtc > Date() else {
                    fputs("No unexpired session is available. Sign in first.\n", stderr)
                    exit(1)
                }
            } else if args == ["--sign-out"] {
                let store = keychain
                if let saved = try store.load(origin: api.origin) { try await api.revoke(saved) }
                try store.remove(origin: api.origin)
                print("Native-client session revoked and removed. Website sign-in is unchanged.")
                return
            } else if !args.isEmpty {
                fputs("Usage: reimagined-probe [--login-url-file PATH | --signed-schedule | --check-game-token | --sign-out]\n", stderr)
                exit(2)
            }
            let schedule = try await api.schedule(accessToken: session?.accessToken)
            let formatter = ISO8601DateFormatter()
            print("Server time: \(formatter.string(from: schedule.serverTimeUtc))")
            print("Ladders visible \(session == nil ? "without sign-in" : "after sign-in"): \(schedule.ladders.count)")
            for entry in schedule.ladders { print("\(entry.name): live=\(entry.isLive), policy=\(entry.policyVersion)") }
            let active = try await api.activeLadders(accessToken: session?.accessToken)
            print("Active ladders: \(active.count)")
            print("HTTPS API read verified; native game admission and server saves remain disconnected.")
        } catch {
            fputs("Reimagined probe failed: \(error)\n", stderr)
            exit(1)
        }
    }
}
