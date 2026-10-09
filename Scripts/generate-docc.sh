#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -ne 4 ]; then
    echo "usage: $0 <target> <catalog> <output-path> <hosting-base-path>" >&2
    exit 64
fi

target="$1"
catalog="$2"
output_path="$3"
hosting_base_path="$4"
symbol_graph="$(find .build/out/Products/Debug -path "*/${target}.symbolgraphs/${target}.symbols.json" -print -quit)"

if [ -z "$symbol_graph" ]; then
    echo "Missing primary symbol graph for ${target}. Run 'make docs', which emits it via swift-docc-plugin." >&2
    exit 1
fi

temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/walletkit-docc.XXXXXX")"
trap 'rm -rf "$temporary_directory"' EXIT

cp "$symbol_graph" "$temporary_directory/"

xcrun docc convert "$catalog" \
    --additional-symbol-graph-dir "$temporary_directory" \
    --output-path "$output_path" \
    --fallback-bundle-identifier "com.reefr.${target}" \
    --fallback-default-module-kind Framework \
    --fallback-display-name "$target" \
    --hosting-base-path "$hosting_base_path" \
    --transform-for-static-hosting
