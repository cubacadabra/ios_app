#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
rust_dir="$project_dir/../rust"
check_dir=$(mktemp -d /tmp/cubacadabra-app-contract.XXXXXX)
if command -v rustup >/dev/null 2>&1; then
    cargo_command="rustup run stable cargo"
else
    cargo_command=cargo
fi
$cargo_command build --manifest-path "$rust_dir/crates/app/Cargo.toml" --target-dir "$rust_dir/target"
xcrun swiftc -parse-as-library \
    -import-objc-header "$rust_dir/include/cubacadabra_app.h" \
    "$project_dir/cubacadabra/AppRuntimeBridge.swift" \
    "$project_dir/scripts/check_app_contract.swift" \
    "$rust_dir/target/debug/libcubacadabra_app.a" \
    -o "$check_dir/check-app-contract"
"$check_dir/check-app-contract" "$rust_dir/crates/app/tests/username-contract.json"
