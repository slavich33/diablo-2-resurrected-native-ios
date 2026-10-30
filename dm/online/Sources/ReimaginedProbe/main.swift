// 只读探针：原生读取赛季列表，不创建会话或写入角色。
// Read-only probe: fetch the ladder schedule natively without creating sessions or writing characters.
import Foundation
import ReimaginedClient

@main
struct Probe {
    static func main() async {
        do {
            let api = try ReimaginedAPIClient()
            var session: LauncherSession?
            let args = Array(CommandLine.arguments.dropFirst())
            if args.count == 2, args[0] == "--login-url-file" {
                let login = try LoopbackLogin()
                let file = URL(fileURLWithPath: args[1])
                try login.authorization.authorizationURL().absoluteString.write(to: file, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                print("Waiting for browser authorization on the random loopback port.")
                fflush(stdout)
                let callback = try await login.waitForCallback(timeout: 600)
                session = try await api.exchange(authorization: login.authorization, callback: callback)
                try SessionKeychain().save(session!, origin: api.origin)
                print("Authorized session stored in this application's local Keychain.")
            } else if args == ["--signed-schedule"] {
                session = try SessionKeychain().load(origin: api.origin)
                guard let saved = session, saved.expiresAtUtc > Date() else {
                    fputs("No unexpired session is available. Sign in first.\n", stderr)
                    exit(1)
                }
            } else if args == ["--sign-out"] {
                let store = SessionKeychain()
                if let saved = try store.load(origin: api.origin) { try await api.revoke(saved) }
                try store.remove(origin: api.origin)
                print("Native-client session revoked and removed. Website sign-in is unchanged.")
                return
            } else if !args.isEmpty {
                fputs("Usage: reimagined-probe [--login-url-file PATH | --signed-schedule | --sign-out]\n", stderr)
                exit(2)
            }
            let schedule = try await api.schedule(accessToken: session?.accessToken)
            let formatter = ISO8601DateFormatter()
            print("Server time: \(formatter.string(from: schedule.serverTimeUtc))")
            print("Ladders visible \(session == nil ? "without sign-in" : "after sign-in"): \(schedule.ladders.count)")
            for entry in schedule.ladders { print("\(entry.name): live=\(entry.isLive), policy=\(entry.policyVersion)") }
            let active = try await api.activeLadders(accessToken: session?.accessToken)
            print("Active ladders: \(active.count)")
            print("HTTPS API read verified; gameplay transport and server saves are not implemented.")
        } catch {
            fputs("Reimagined probe failed: \(error)\n", stderr)
            exit(1)
        }
    }
}
