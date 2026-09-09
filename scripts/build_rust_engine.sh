#!/bin/sh
set -eu

project_dir="${PROJECT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
rust_repo_path="${RUST_REPO_PATH:-../rust}"
case "$rust_repo_path" in
  /*) rust_repo_dir="$rust_repo_path" ;;
  *) rust_repo_dir="$project_dir/$rust_repo_path" ;;
esac
client_manifest_path="$rust_repo_dir/crates/client/Cargo.toml"
app_manifest_path="$rust_repo_dir/crates/app/Cargo.toml"
output_dir="${DERIVED_FILE_DIR:-$project_dir/rust/build}/cubacadabra-engine"
cargo_target_dir="${CARGO_TARGET_DIR:-${DERIVED_FILE_DIR:-$project_dir/rust/build}/rust-target}"
rust_profile=debug
cargo_profile_args=

if [ "${CONFIGURATION:-Debug}" = "Release" ]; then
  rust_profile=release
  cargo_profile_args=--release
fi

if ! command -v rustc >/dev/null 2>&1 || ! command -v cargo >/dev/null 2>&1; then
  if [ -x "${HOME:-}/.cargo/bin/rustup" ]; then
    PATH="${HOME}/.cargo/bin:$PATH"
    export PATH
  fi
fi

if command -v rustup >/dev/null 2>&1; then
  rustc_command="rustup run stable rustc"
  cargo_command="rustup run stable cargo"
else
  rustc_command="rustc"
  cargo_command="cargo"
fi

if ! command -v rustc >/dev/null 2>&1 || ! command -v cargo >/dev/null 2>&1; then
  echo "Rust is required to build the Cubacadabra engine." >&2
  exit 1
fi

mkdir -p "$output_dir"
case "${PLATFORM_NAME:-iphonesimulator}" in
  iphoneos) rust_targets="aarch64-apple-ios" ;;
  iphonesimulator)
    rust_targets=""
    case " ${ARCHS:-arm64} " in *" arm64 "*) rust_targets="$rust_targets aarch64-apple-ios-sim" ;; esac
    case " ${ARCHS:-arm64} " in *" x86_64 "*) rust_targets="$rust_targets x86_64-apple-ios" ;; esac
    ;;
  *) echo "Unsupported Rust platform: ${PLATFORM_NAME:-unknown}" >&2; exit 1 ;;
esac

for rust_target in $rust_targets; do
  if ! $rustc_command --print target-libdir --target "$rust_target" >/dev/null 2>&1; then
    rustup target add "$rust_target"
  fi
  CARGO_TARGET_DIR="$cargo_target_dir" $cargo_command build --manifest-path "$client_manifest_path" --target "$rust_target" --features metal $cargo_profile_args
  CARGO_TARGET_DIR="$cargo_target_dir" $cargo_command build --manifest-path "$app_manifest_path" --target "$rust_target" $cargo_profile_args
done

copy_or_combine_archives() {
  archive_name="$1"
  output_path="$2"
  set --
  for rust_target in $rust_targets; do
    set -- "$@" "$cargo_target_dir/$rust_target/$rust_profile/$archive_name"
  done
  if [ "$#" -eq 0 ]; then
    echo "No Rust library was built for PLATFORM_NAME=${PLATFORM_NAME:-unknown}, ARCHS=${ARCHS:-unknown}." >&2
    exit 1
  elif [ "$#" -eq 1 ]; then
    cp "$1" "$output_path"
  else
    lipo -create "$@" -output "$output_path"
  fi
}

copy_or_combine_archives libcubacadabra_client.a "$output_dir/libcubacadabra_engine.a"
copy_or_combine_archives libcubacadabra_app.a "$output_dir/libcubacadabra_app.a"
