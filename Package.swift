// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "postgres-for-swift-log",
    platforms: [
        .macOS(.v13), // 'PostgresClient' is only available in macOS 13.0 or newer
        .iOS(.v16),
        .watchOS(.v9),
        .tvOS(.v16),
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "LoggingToPostgres",
            targets: ["LoggingToPostgres"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git",from: "1.5.2"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.0.0"),
        .package(url: "https://github.com/vapor/postgres-nio", from: "1.25.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "LoggingToPostgres",
            dependencies: [
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "Logging", package: "swift-log"),
            ],
        ),
        .testTarget(
            name: "LoggingToPostgresTests",
            dependencies: ["LoggingToPostgres"]
        ),
    ]
)
