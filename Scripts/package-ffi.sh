#!/usr/bin/env bash
# Packs the built XCFramework and Licenses/ into the release ZIP, writes its
# SwiftPM checksum, and archives the libusb source Cargo compiled.

set -euo pipefail

if [ "$#" -ne 3 ]; then
    echo "usage: $0 <xcframework> <rust-workspace-dir> <output-dir>" >&2
    exit 64
fi

xcframework="$1"
rust_dir="$2"
output_dir="$3"
name="$(basename "$xcframework")"

test -d "$xcframework" || { echo "Missing $xcframework" >&2; exit 1; }

libusb_sys_dir="$(cargo metadata --format-version 1 --locked --manifest-path "$rust_dir/Cargo.toml" |
    python3 -I -c 'import json, os, sys
packages = [p for p in json.load(sys.stdin)["packages"] if p["name"] == "libusb1-sys"]
assert len(packages) == 1, "expected exactly one libusb1-sys"
print(os.path.dirname(packages[0]["manifest_path"]))')"
libusb_version="$(sed -n 's/^static VERSION: &str = "\(.*\)";$/\1/p' "$libusb_sys_dir/build.rs")"

test -n "$libusb_version" || { echo "Can't read libusb version from $libusb_sys_dir/build.rs" >&2; exit 1; }
cmp -s Licenses/libusb-COPYING "$libusb_sys_dir/libusb/COPYING" ||
    { echo "Licenses/libusb-COPYING differs from $libusb_sys_dir/libusb/COPYING" >&2; exit 1; }
grep -q "libusb $libusb_version " Licenses/NOTICE ||
    { echo "Licenses/NOTICE doesn't name libusb $libusb_version" >&2; exit 1; }

rm -rf "$output_dir"
mkdir -p "$output_dir/stage"
ditto "$xcframework" "$output_dir/stage/$name"
ditto Licenses "$output_dir/stage/Licenses"
# -y keeps symlinks intact; the XCFramework and Licenses/ sit at the ZIP root.
(cd "$output_dir/stage" && zip -qry -X ../"$name.zip" "$name" Licenses)
rm -rf "$output_dir/stage"

swift package compute-checksum "$output_dir/$name.zip" > "$output_dir/$name.zip.checksum"

tar -czf "$output_dir/libusb-$libusb_version-source.tar.gz" \
    -C "$libusb_sys_dir" --exclude .DS_Store -s ",^libusb,libusb-$libusb_version," libusb

echo "==> $output_dir/$name.zip ($(du -h "$output_dir/$name.zip" | cut -f1)), checksum $(cat "$output_dir/$name.zip.checksum")"
echo "==> $output_dir/libusb-$libusb_version-source.tar.gz"
