import Foundation
import ProjectDescription
import ProjectDescriptionHelpers

private let walletKitGRPC: Target = .target(
    name: "WalletKitGRPC",
    destinations: [.mac, .iPhone, .iPad],
    product: .staticFramework,
    bundleId: "xyz.reefr.wallet.walletkit.grpc",
    deploymentTargets: Project.deploymentTargets,
    infoPlist: .extendingDefault(with: Project.commonInfoPlist),
    buildableFolders: ["Sources/Generated/gRPC"],
    dependencies: [
        .external(name: "SwiftProtobuf"),
        .external(name: "GRPCCore"),
        .external(name: "GRPCNIOTransportHTTP2Posix"),
        .external(name: "GRPCProtobuf")
    ]
)

private let walletKitRust: Target = .target(
    name: "WalletKitRust",
    destinations: [.mac, .iPhone, .iPad],
    product: .staticFramework,
    bundleId: "xyz.reefr.wallet.walletkit.rust",
    deploymentTargets: Project.deploymentTargets,
    infoPlist: .extendingDefault(with: Project.commonInfoPlist),
    buildableFolders: ["Sources/Generated/Bindings"],
    dependencies: [
        .xcframework(path: "Frameworks/WalletKit.xcframework")
    ]
)

private let walletKit: Target = .target(
    name: "WalletKit",
    destinations: [.mac, .iPhone, .iPad],
    product: .staticFramework,
    bundleId: "xyz.reefr.wallet.walletkit",
    deploymentTargets: Project.deploymentTargets,
    infoPlist: .extendingDefault(with: Project.commonInfoPlist),
    buildableFolders: ["Sources/WalletKit"],
    scripts: [
        .post(
            script: """
                    $HOME/.local/bin/mise -C $SRCROOT x swiftlint -- \\
                    swiftlint --quiet --config ../.swiftlint.yml Sources/Static Project.swift
                    """,
            name: "SwiftLint",
            basedOnDependencyAnalysis: false
        )
    ],
    dependencies: [
        .external(name: "BigInt"),
        .external(name: "GRPCCore"),
        .external(name: "GRPCNIOTransportHTTP2Posix"),
        .target(name: "WalletKitGRPC"),
        .target(name: "WalletKitRust")
    ]
)

private let walletKitTesting: Target = .target(
    name: "WalletKitTesting",
    destinations: [.mac],
    product: .staticFramework,
    bundleId: "xyz.reefr.wallet.walletkit.testing",
    deploymentTargets: .macOS("15.0"),
    infoPlist: .extendingDefault(with: Project.commonInfoPlist),
    buildableFolders: ["Sources/WalletKitTesting"],
    dependencies: [
        .external(name: "BigInt"),
        .external(name: "GRPCCore"),
        .external(name: "GRPCNIOTransportHTTP2Posix"),
        .target(name: "WalletKit"),
        .target(name: "WalletKitGRPC")
    ]
)

private let walletKitTestsMac: Target = .target(
    name: "WalletKitTests-macOS",
    destinations: [.mac],
    product: .unitTests,
    bundleId: "xyz.reefr.wallet.walletkit.tests-mac",
    deploymentTargets: .macOS("15.0"),
    resources: ["TestVectors/**/*"],
    buildableFolders: ["Tests"],
    scripts: [
        .post(
            script: """
                    $HOME/.local/bin/mise -C $SRCROOT x swiftlint -- \\
                    swiftlint --quiet --config ../.swiftlint.yml Tests
                    """,
            name: "SwiftLint",
            basedOnDependencyAnalysis: false
        )
    ],
    dependencies: [
        .external(name: "BigInt"),
        .target(name: "WalletKit"),
        .target(name: "WalletKitRust"),
        .target(name: "WalletKitTesting"),
        .target(name: "WalletKitGRPC")
    ]
)

private let schemes: [Scheme] = [
    .scheme(
        name: walletKit.name,
        buildAction: .buildAction(targets: ["\(walletKit.name)"]),
        testAction: .targets(
            ["\(walletKitTestsMac.name)"],
            options: .options(coverage: true, codeCoverageTargets: ["\(walletKit.name)"])
        )
    )
]

private let libUsbPathFlag = if FileManager.default.fileExists(atPath: "/usr/local/opt/libusb/lib") {
    "-L/usr/local/opt/libusb/lib"
} else {
    "-L/opt/homebrew/opt/libusb/lib"
}

let project = Project(
    name: "WalletKit",
    organizationName: Project.organizationName,
    settings: .settings(base: [
        "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS": true,
        "ENABLE_MODULE_VERIFIER": true,
        "ENABLE_USER_SCRIPT_SANDBOXING": false,
        "MODULE_VERIFIER_SUPPORTED_LANGUAGE_STANDARDS": ["gnu11", "gnu++14"],
        "OTHER_LDFLAGS[sdk=macosx*]": ["-lc++", libUsbPathFlag, "-lusb-1.0"],
        "STRING_CATALOG_GENERATE_SYMBOLS": true
    ]),
    targets: [walletKitRust, walletKitGRPC, walletKit, walletKitTesting, /*walletKitTestsIOS,*/ walletKitTestsMac],
    schemes: schemes,
    additionalFiles: [
        "*.md",
        "Docs/**/*",
        "Rust/walletkit-ffi/**/*",
        "Rust/Cargo.toml",
        "Rust/README.md",
        "Makefile",
        "Project.swift"
    ]
)
