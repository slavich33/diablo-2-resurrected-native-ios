// swift-tools-version: 5.9
// 原生 API 与 TCP 传输组件；尚未接入游戏准入和服务器角色。
// Native API and TCP transport components; game admission and server characters remain disconnected.
import PackageDescription

let package = Package(
    name: "ReimaginedOnline",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "ReimaginedClient", targets: ["ReimaginedClient"]),
        .executable(name: "reimagined-probe", targets: ["ReimaginedProbe"])
    ],
    targets: [
        .target(name: "ReimaginedClient"),
        .executableTarget(name: "ReimaginedProbe", dependencies: ["ReimaginedClient"]),
        .testTarget(name: "ReimaginedClientTests", dependencies: ["ReimaginedClient"], resources: [.process("Fixtures")])
    ]
)
