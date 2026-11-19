#!/usr/bin/env bash
# Builds a throwaway package that links WalletKit, for macOS (and runs it) and
# for the iOS Simulator.
#
#   consumer-check.sh zip <WalletKitFFI.xcframework.zip>  # this checkout + that ZIP
#   consumer-check.sh remote <version>                    # the published release

set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: $0 zip <path> | remote <version>" >&2
    exit 64
fi

mode="$1"
argument="$2"
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/walletkit-consumer.XXXXXX")"
local_ffi="$repo/Frameworks/WalletKitFFI.xcframework"
hidden_ffi="$repo/Frameworks/.WalletKitFFI.xcframework.consumer-check"

restore() {
    if [ -d "$hidden_ffi" ]; then
        mv "$hidden_ffi" "$local_ffi"
    fi
}
trap restore EXIT

case "$mode" in
zip)
    test -f "$argument" || { echo "Missing $argument" >&2; exit 1; }
    # Binary target paths are package-relative: copy the ZIP into the package.
    mkdir -p "$repo/.build/consumer-check"
    cp "$argument" "$repo/.build/consumer-check/WalletKitFFI.xcframework.zip"
    export WALLETKIT_FFI_ZIP=".build/consumer-check/WalletKitFFI.xcframework.zip"
    # Hide the local build so a missed WALLETKIT_FFI_ZIP fails instead of passing.
    if [ -d "$local_ffi" ]; then
        mv "$local_ffi" "$hidden_ffi"
    fi
    dependency=".package(name: \"WalletKit\", path: \"$repo\")"
    ;;
remote)
    dependency=".package(url: \"https://github.com/ReefrWallet/WalletKit\", exact: \"$argument\")"
    ;;
*)
    echo "usage: $0 zip <path> | remote <version>" >&2
    exit 64
    ;;
esac

mkdir -p "$work/Sources/Consumer" "$work/Sources/ConsumerCheck"
cat > "$work/Package.swift" <<EOF
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Consumer",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "Consumer", type: .dynamic, targets: ["Consumer"]),
        .executable(name: "consumer-check", targets: ["ConsumerCheck"])
    ],
    dependencies: [$dependency],
    targets: [
        .target(name: "Consumer", dependencies: [.product(name: "WalletKit", package: "WalletKit")]),
        .executableTarget(name: "ConsumerCheck", dependencies: ["Consumer"])
    ],
    swiftLanguageModes: [.v5]
)
EOF
cat > "$work/Sources/Consumer/Consumer.swift" <<'EOF'
import WalletKit

public func generatedWordCount() -> Int {
    Mnemonic.generate(wordCount: .`12`).phrase.split(separator: " ").count
}
EOF
cat > "$work/Sources/ConsumerCheck/main.swift" <<'EOF'
import Consumer

let count = generatedWordCount()
precondition(count == 12, "Expected 12 words, got \(count)")
print("WalletKit consumer check passed")
EOF

echo "==> Consumer check ($mode $argument): macOS"
(cd "$work" && swift run --cache-path "$work/cache" consumer-check)

echo "==> Consumer check ($mode $argument): iOS Simulator"
(cd "$work" && xcodebuild -quiet -scheme Consumer -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$work/DerivedData" -clonedSourcePackagesDirPath "$work/SourcePackages" \
    -packageCachePath "$work/cache" build)

rm -rf "$work"
