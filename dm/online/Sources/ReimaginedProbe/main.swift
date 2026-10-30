// 只读探针：原生读取赛季列表，不创建会话或写入角色。
// Read-only probe: fetch the ladder schedule natively without creating sessions or writing characters.
import Foundation
import ReimaginedClient

@main
struct Probe {
    static func main() async {
        do {
            let schedule = try await ReimaginedAPIClient().schedule()
            let formatter = ISO8601DateFormatter()
            print("Server time: \(formatter.string(from: schedule.serverTimeUtc))")
            print("Ladders visible without sign-in: \(schedule.ladders.count)")
            for entry in schedule.ladders { print("\(entry.name): live=\(entry.isLive), policy=\(entry.policyVersion)") }
            print("HTTPS API read verified; gameplay transport and server saves are not implemented.")
        } catch {
            fputs("Schedule probe failed: \(error)\n", stderr)
            exit(1)
        }
    }
}
