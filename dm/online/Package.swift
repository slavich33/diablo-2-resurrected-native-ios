// swift-tools-version: 5.9
// 原生 Apple 平台上的 Reimagined API 协议研究，不含游戏联网实现。
// Reimagined API contract research for native Apple platforms; no gameplay networking implementation.
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
