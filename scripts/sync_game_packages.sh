#!/bin/sh
set -eu

project_dir="${PROJECT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
tools_dir="$project_dir/../tools"
game_package_build="${DERIVED_FILE_DIR:-$project_dir/rust/build}/game-package"

if [ -z "${TARGET_BUILD_DIR:-}" ] || [ -z "${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}" ]; then
  echo "Xcode bundle paths are required to sync game packages." >&2
  exit 1
fi
bundle_resources_destination="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"

if [ ! -f "$tools_dir/pyproject.toml" ] || [ ! -d "$tools_dir/src/cubacadabra" ]; then
  echo "The shared Cubacadabra tools checkout is missing: $tools_dir" >&2
  exit 1
fi

sync_game_package() {
  game_id="$1"
  game_project="$project_dir/../$game_id"
  package_build="$game_package_build/$game_id"
  manifest_destination="$bundle_resources_destination/manifest-$game_id.json"
  script_destination="$bundle_resources_destination/game-$game_id.luau"

  if [ ! -f "$game_project/manifest.json" ] || [ ! -f "$game_project/src/main.luau" ]; then
    echo "The $game_id game project is missing manifest.json or src/main.luau: $game_project" >&2
    exit 1
  fi

  echo "Building $game_id package into the iOS app bundle."
  PYTHONPATH="$tools_dir/src${PYTHONPATH:+:$PYTHONPATH}" \
    python3 -m cubacadabra build-game "$game_project" --output "$package_build"
  mkdir -p "$bundle_resources_destination"
  cp "$package_build/manifest.json" "$manifest_destination"
  cp "$package_build/game.luau" "$script_destination"
  if [ -d "$package_build/assets" ]; then
    mkdir -p "$bundle_resources_destination/assets-$game_id"
    cp -R "$package_build/assets/." "$bundle_resources_destination/assets-$game_id/"
  fi
}

for game_id in first-game second-game; do
  sync_game_package "$game_id"
done
