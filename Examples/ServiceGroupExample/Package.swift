// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "ServiceGroupExample",
    platforms: [
        .macOS(.v13),  // 'PostgresClient' is only available in macOS 13.0 or newer
        .iOS(.v16),
        .watchOS(.v9),
        .tvOS(.v16),
    ],
    dependencies: [
        .package(path: "../../")
    ],
    targets: [
        .executableTarget(
            name: "ServiceGroupExample",
            dependencies: [.product(name: "LoggingToPostgres", package: "postgres-for-swift-log")]
        )
    ]
)
