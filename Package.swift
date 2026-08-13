// swift-tools-version: 6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Terminal",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [.library(name: "Terminal", targets: ["Terminal"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio-ssh", exact: "0.15.0"),
        .package(url: "https://github.com/apple/swift-nio", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-crypto", from: "4.0.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "Terminal",
            dependencies: [
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
                .defaultIsolation(MainActor.self),
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)
