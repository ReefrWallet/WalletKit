// swift-tools-version: 6.0

import Foundation
import PackageDescription

// Rust FFI binary: a local build (`make walletkit-ffi`), then the GitHub
// release. `Scripts/release.sh` rewrites the two lines below.
let ffiVersion = "0.9.1"
let ffiChecksum = "222c00cf99fb3cd59e122c84f4cc20bf7014daac655a2cc96b086cd7e552c810"

let ffiTarget: Target = {
    let localPath = "Frameworks/WalletKitFFI.xcframework"

    if Context.environment["WALLETKIT_REMOTE_FFI"] == nil,
       FileManager.default.fileExists(atPath: "\(Context.packageDirectory)/\(localPath)") {
        return .binaryTarget(name: "WalletKitFFI", path: localPath)
    }

    return .binaryTarget(
        name: "WalletKitFFI",
        url: "https://github.com/ReefrWallet/WalletKit/releases/download/\(ffiVersion)/WalletKitFFI.xcframework.zip",
        checksum: ffiChecksum
    )
}()

// The test target is rooted at "." for TestVectors; skip the rest that exists.
let testExcludes = [
    ".build", ".DS_Store", ".git", ".github", ".gitignore", ".gitmodules", ".swiftpm", "Derived", "docs",
    "Frameworks", "LICENSE", "Licenses", "Makefile", "mise.toml", "Package.resolved", "Package.swift",
    "README.md", "Scripts", "Site", "Sources", "WalletKit.xcodeproj"
].filter { FileManager.default.fileExists(atPath: "\(Context.packageDirectory)/\($0)") }

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
        ),
        .library(
            name: "WalletKitTesting",
            targets: ["WalletKitTesting"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/Alamofire/Alamofire", from: "5.12.0"),
        .package(url: "https://github.com/apple/swift-protobuf", from: "1.38.0"),
        .package(url: "https://github.com/attaswift/BigInt", from: "6.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-2", from: "2.4.0"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport", from: "2.9.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf", from: "2.4.0"),
        .package(url: "https://github.com/Moya/Moya", from: "15.0.3"),
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.5.0")
    ],
    targets: [
        ffiTarget,
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
            path: "Sources/Generated/Bindings",
            linkerSettings: [
                .linkedLibrary("c++"),
                // Statically linked libusb (rusb's `vendored` feature).
                .linkedFramework("CoreFoundation", .when(platforms: [.macOS])),
                .linkedFramework("IOKit", .when(platforms: [.macOS])),
                .linkedFramework("Security", .when(platforms: [.macOS])),
                .linkedLibrary("objc", .when(platforms: [.macOS]))
            ]
        ),
        .target(
            name: "WalletKit",
            dependencies: [
                .product(name: "Alamofire", package: "Alamofire"),
                .product(name: "BigInt", package: "BigInt"),
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2Posix", package: "grpc-swift-nio-transport"),
                .product(name: "Moya", package: "Moya"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                "WalletKitGRPC",
                "WalletKitRust"
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
                .product(name: "Alamofire", package: "Alamofire"),
                .product(name: "BigInt", package: "BigInt"),
                .product(name: "Moya", package: "Moya"),
                "WalletKit",
                "WalletKitRust",
                "WalletKitTesting"
            ],
            path: ".",
            exclude: testExcludes,
            sources: ["Tests"],
            resources: [.process("TestVectors")]
        )
    ],
    swiftLanguageModes: [.v5]
)
