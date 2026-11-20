#!/usr/bin/env bash
# Builds and verifies WalletKit <version>, then with PUBLISH=1 commits the
# release manifest, tags it, pushes, and publishes the GitHub release.
# Without PUBLISH it is a dry run: nothing is committed, tagged or pushed.

set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "usage: [PUBLISH=1] $0 <major.minor.patch>" >&2
    exit 64
fi

version="$1"
publish="${PUBLISH:-}"
release_dir=".build/release"
rust_dir="Sources/Rust"
zip="$release_dir/WalletKitFFI.xcframework.zip"

cd "$(dirname "$0")/.."

fail() {
    echo "release: $*" >&2
    exit 1
}

# Files the release commit changes; a dry run restores them.
release_files=(Package.swift "$rust_dir/Cargo.lock" "$rust_dir/Cargo.toml")

restore_release_files() {
    git checkout --quiet -- "${release_files[@]}"
}

echo "==> Checking preconditions for $version"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "$version isn't major.minor.patch"
[ "$(git symbolic-ref --quiet --short HEAD)" = main ] || fail "not on main"
[ -z "$(git status --porcelain)" ] || fail "worktree isn't clean"
git fetch --quiet origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || fail "HEAD isn't origin/main"
! git rev-parse --quiet --verify "refs/tags/$version" >/dev/null || fail "tag $version exists locally"
[ -z "$(git ls-remote --tags origin "refs/tags/$version")" ] || fail "tag $version exists on origin"
if [ -n "$publish" ]; then
    command -v gh >/dev/null || fail "PUBLISH needs the gh CLI"
    ! gh release view "$version" >/dev/null 2>&1 || fail "release $version exists"
fi

[ -n "$publish" ] || trap restore_release_files EXIT

echo "==> Setting the Rust crates to $version"
sed -i '' -E '/^\[workspace\.package\]$/,/^\[/ s/^version = ".*"$/version = "'"$version"'"/' "$rust_dir/Cargo.toml"
grep -qx "version = \"$version\"" "$rust_dir/Cargo.toml" || fail "couldn't set the workspace version"
cargo update --workspace --manifest-path "$rust_dir/Cargo.toml"

echo "==> Building all slices"
make -B walletkit-ffi RELEASE=1
make -B sui-grpc RELEASE=1

echo "==> Testing"
make test RELEASE=1
make docs RELEASE=1
[ -z "$(git status --porcelain -- Sources/Generated)" ] ||
    fail "generated sources differ from main; commit them first: $(git status --porcelain -- Sources/Generated)"

echo "==> Packaging"
Scripts/package-ffi.sh Frameworks/WalletKitFFI.xcframework Sources/Rust "$release_dir"
checksum="$(cat "$zip.checksum")"

sed -i '' -E \
    -e "s/^let ffiVersion = \".*\"$/let ffiVersion = \"$version\"/" \
    -e "s/^let ffiChecksum = \".*\"$/let ffiChecksum = \"$checksum\"/" \
    Package.swift
grep -qx "let ffiVersion = \"$version\"" Package.swift || fail "couldn't set ffiVersion"
grep -qx "let ffiChecksum = \"$checksum\"" Package.swift || fail "couldn't set ffiChecksum"

if [ -z "$publish" ]; then
    echo "==> Dry run passed: $zip ($checksum). Nothing was committed, tagged or pushed."
    exit 0
fi

echo "==> Committing and tagging $version"
if [ -n "${GITHUB_ACTIONS:-}" ]; then
    git config user.name "github-actions[bot]"
    git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
fi
git add "${release_files[@]}"
git commit --quiet -m "Release $version"
git tag -a "$version" -m "WalletKit $version"
[ "$(git rev-parse "$version^{commit}")" = "$(git rev-parse HEAD)" ] || fail "tag doesn't point at HEAD"
git show "$version:Package.swift" | grep -qx "let ffiChecksum = \"$checksum\"" || fail "tagged manifest lacks the checksum"
git show "$version:Package.swift" | grep -qx "let ffiVersion = \"$version\"" || fail "tagged manifest lacks the version"
git show "$version:$rust_dir/Cargo.toml" | grep -qx "version = \"$version\"" || fail "tagged Rust workspace lacks the version"

echo "==> Publishing $version"
git push --atomic origin HEAD:refs/heads/main "refs/tags/$version"
gh release create "$version" "$zip" "$release_dir"/libusb-*-source.tar.gz \
    --verify-tag --title "$version" --generate-notes \
    --notes "SwiftPM checksum of WalletKitFFI.xcframework.zip: \`$checksum\`"

echo "==> Released $version"
