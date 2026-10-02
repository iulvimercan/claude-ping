#!/usr/bin/env bash
# Builds the Lambda artifacts. Linux only (CI runner or WSL).
#
#   scripts/build.sh function   -> dist/function.zip        (handler only, a few KB)
#   scripts/build.sh cli        -> dist/cli/layer-N.zip     (Claude Code binary, zstd + split)
#                                  dist/cli/key.txt         (identifies the binary + recipe)
#
# The Claude Code linux-x64 binary is ~240 MB, so it can't be uploaded directly
# (50 MB zip limit) without S3. It's compressed with zstd (~85 MB) and split into
# parts, one Lambda layer each. src/index.mjs reassembles it into /tmp on cold start.
set -euo pipefail

cd "$(dirname "$0")/.."

# Bump when the compression/split recipe changes so the layers get republished
RECIPE="zstd19-long27-v1"
PART_SIZE="40M"
MAX_LAYERS=5
MAX_ZIP_BYTES=52428800         # 50 MB direct-upload limit per zip
MAX_UNZIPPED_BYTES=262144000   # 250 MB function + layers limit

size_of() { stat -c %s "$1"; }

build_function() {
  rm -rf build/function dist/function.zip
  mkdir -p build/function dist
  cp src/index.mjs build/function/
  (cd build/function && zip -qX ../../dist/function.zip index.mjs)
  echo "function.zip: $(size_of dist/function.zip) bytes"
}

cli_version() {
  node -p "require('./package-lock.json').packages['node_modules/@anthropic-ai/claude-code'].version"
}

build_cli() {
  local version key
  version="$(cli_version)"
  key="claude-code@${version} ${RECIPE}"

  rm -rf build/cli dist/cli
  mkdir -p build/cli dist/cli

  # Lockfile pins the version and verifies the binary's integrity hash.
  # --ignore-scripts skips the postinstall that would copy the binary elsewhere.
  mkdir -p build/cli/npm
  cp package.json package-lock.json build/cli/npm/
  (cd build/cli/npm && npm ci --omit=dev --os=linux --cpu=x64 --ignore-scripts --no-audit --no-fund >/dev/null)
  local bin=build/cli/npm/node_modules/@anthropic-ai/claude-code-linux-x64/claude
  if [[ ! -f "$bin" ]]; then
    echo "Claude Code linux-x64 binary not found at $bin" >&2
    exit 1
  fi
  echo "binary: $(size_of "$bin") bytes (claude-code ${version})"

  zstd -q -T0 -19 --long=27 "$bin" -o build/cli/claude.zst
  echo "claude.zst: $(size_of build/cli/claude.zst) bytes"

  mkdir -p build/cli/parts
  split -b "$PART_SIZE" -d -a 2 build/cli/claude.zst build/cli/parts/claude.zst.part

  local parts=(build/cli/parts/claude.zst.part*)
  local count=${#parts[@]}
  if (( count > MAX_LAYERS )); then
    echo "Needs $count layers, Lambda allows $MAX_LAYERS" >&2
    exit 1
  fi

  local i=1 total=0
  for part in "${parts[@]}"; do
    # Layers are extracted into /opt, so this lands in /opt/claude-cli/
    local dir="build/cli/layer-$i"
    mkdir -p "$dir/claude-cli"
    cp "$part" "$dir/claude-cli/"
    (cd "$dir" && zip -qX0 "../../../dist/cli/layer-$i.zip" claude-cli/*)
    local zip_size
    zip_size=$(size_of "dist/cli/layer-$i.zip")
    echo "layer-$i.zip: $zip_size bytes"
    if (( zip_size > MAX_ZIP_BYTES )); then
      echo "layer-$i.zip exceeds the 50 MB direct-upload limit" >&2
      exit 1
    fi
    total=$(( total + $(size_of "$part") ))
    i=$(( i + 1 ))
  done

  if (( total > MAX_UNZIPPED_BYTES )); then
    echo "Unzipped layers ($total bytes) exceed the 250 MB limit" >&2
    exit 1
  fi

  echo "$key" > dist/cli/key.txt
  echo "$count" > dist/cli/count.txt
  echo "cli: $count layer(s), key '$key'"
}

case "${1:-}" in
  function) build_function ;;
  cli) build_cli ;;
  key) echo "claude-code@$(cli_version) ${RECIPE}" ;;
  *) echo "usage: $0 function|cli|key" >&2; exit 2 ;;
esac
