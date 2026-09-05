#!/bin/sh
set -eu

project_dir="${PROJECT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
manifest_path="$project_dir/../rust/Cargo.toml"
tools_dir="$project_dir/../tools"
game_project="$project_dir/../first-game"
game_package_build="${DERIVED_FILE_DIR:-$project_dir/rust/build}/game-package"
game_resources_destination="$project_dir/cubacadabra/Resources"
output_dir="${DERIVED_FILE_DIR:-$project_dir/rust/build}/cubacadabra-engine"
cargo_target_dir="${CARGO_TARGET_DIR:-${DERIVED_FILE_DIR:-$project_dir/rust/build}/rust-target}"
rust_profile=debug
cargo_profile_args=

if [ "${CONFIGURATION:-Debug}" = "Release" ]; then
  rust_profile=release
  cargo_profile_args=--release
fi

if [ ! -f "$tools_dir/pyproject.toml" ] || [ ! -d "$tools_dir/src/cubacadabra" ]; then
  echo "The shared Cubacadabra tools checkout is missing: $tools_dir" >&2
  exit 1
fi
echo "Building the default game package into the iOS bundle resources."
PYTHONPATH="$tools_dir/src${PYTHONPATH:+:$PYTHONPATH}" \
  python3 -m cubacadabra build-game "$game_project" --output "$game_package_build"
cp "$game_package_build/manifest.json" "$game_resources_destination/manifest.json"
cp "$game_package_build/game.luau" "$game_resources_destination/game.luau"
if [ -d "$game_package_build/assets" ]; then
  mkdir -p "$game_resources_destination/assets"
  cp -R "$game_package_build/assets/." "$game_resources_destination/assets/"
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

set --
for rust_target in $rust_targets; do
  if ! $rustc_command --print target-libdir --target "$rust_target" >/dev/null 2>&1; then
    rustup target add "$rust_target"
  fi
  CARGO_TARGET_DIR="$cargo_target_dir" $cargo_command build --manifest-path "$manifest_path" --target "$rust_target" $cargo_profile_args
  set -- "$@" "$cargo_target_dir/$rust_target/$rust_profile/libcubacadabra_engine.a"
done

if [ "$#" -eq 0 ]; then
  echo "No Rust library was built for PLATFORM_NAME=${PLATFORM_NAME:-unknown}, ARCHS=${ARCHS:-unknown}." >&2
  exit 1
elif [ "$#" -eq 1 ]; then
  cp "$1" "$output_dir/libcubacadabra_engine.a"
else
  lipo -create "$@" -output "$output_dir/libcubacadabra_engine.a"
fi
