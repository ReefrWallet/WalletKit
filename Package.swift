// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "WalletKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "WalletKit",
            targets: ["WalletKit"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf", from: "1.38.0"),
        .package(url: "https://github.com/attaswift/BigInt", from: "6.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-2", from: "2.4.0"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport", from: "2.9.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf", from: "2.4.0"),
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.5.0")
    ],
    targets: [
        .systemLibrary(
            name: "CLibUSB",
            pkgConfig: "libusb-1.0",
            providers: [.brew(["libusb"])]
        ),
        .binaryTarget(
            name: "WalletKitFFI",
            path: "Frameworks/WalletKit.xcframework"
        ),
        .target(
            name: "WalletKitGRPC",
            dependencies: [
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf")
            ],
            path: "Sources/Generated/gRPC"
        ),
        .target(
            name: "WalletKitRust",
            dependencies: ["WalletKitFFI"],
            path: "Sources/Generated/Bindings"
        ),
        .target(
            name: "WalletKit",
            dependencies: [
                .product(name: "BigInt", package: "BigInt"),
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2Posix", package: "grpc-swift-nio-transport"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                "WalletKitGRPC",
                "WalletKitRust",
                .target(name: "CLibUSB", condition: .when(platforms: [.macOS]))
            ],
            path: "Sources/WalletKit"
        ),
        .target(
            name: "WalletKitTesting",
            dependencies: [
                .product(name: "BigInt", package: "BigInt"),
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2Posix", package: "grpc-swift-nio-transport"),
                "WalletKit",
                "WalletKitGRPC"
            ],
            path: "Sources/WalletKitTesting"
        ),
        .testTarget(
            name: "WalletKitTests",
            dependencies: [
                .product(name: "BigInt", package: "BigInt"),
                "WalletKit",
                "WalletKitRust",
                "WalletKitTesting"
            ],
            path: ".",
            exclude: [
                ".build",
                ".DS_Store",
                ".git",
                ".github",
                ".gitignore",
                ".gitmodules",
                "Derived",
                "Docs",
                "Frameworks",
                "LICENSE",
                "Makefile",
                "mise.toml",
                "Package.swift",
                "Project.swift",
                "README.md",
                "Scripts",
                "Sources",
                "WalletKit.xcodeproj"
            ],
            sources: ["Tests"],
            resources: [.process("TestVectors")]
        )
    ],
    swiftLanguageModes: [.v5]
)
