// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "TokenLedger",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "TokenLedger", targets: ["TokenLedger"])],
    targets: [
        .target(name: "ArchiveReader"),
        .target(name: "LedgerCore", dependencies: ["ArchiveReader"]),
        .executableTarget(name: "TokenLedger", dependencies: ["LedgerCore"]),
        .testTarget(name: "LedgerCoreTests", dependencies: ["LedgerCore"]),
    ]
)
