#!/usr/bin/env bash
# Makes sure the Claude Code CLI layers (claude-ping-cli-1..N) match package-lock.json,
# publishing new versions only when the version or build recipe changed.
# Prints the layer version ARNs, comma-separated and in part order, on stdout.
set -euo pipefail

cd "$(dirname "$0")/.."

RUNTIME=nodejs24.x
KEEP_VERSIONS=2
key="$(bash scripts/build.sh key)"

log() { echo "$*" >&2; }

# Prints "<arn>\t<description>" of a layer's newest version, or "None" if it has none
latest_version() {
  aws lambda list-layer-versions --layer-name "$1" \
    --query 'reverse(sort_by(LayerVersions, &Version))[0].[LayerVersionArn,Description]' --output text
}

current_arns() {
  local arn desc count i
  IFS=$'\t' read -r arn desc <<<"$(latest_version claude-ping-cli-1)"
  [[ "${desc:-}" == "$key part 1/"* ]] || return 1
  count="${desc##*/}"
  local arns=("$arn")
  for (( i = 2; i <= count; i++ )); do
    IFS=$'\t' read -r arn desc <<<"$(latest_version "claude-ping-cli-$i")"
    [[ "${desc:-}" == "$key part $i/$count" ]] || return 1
    arns+=("$arn")
  done
  (IFS=,; echo "${arns[*]}")
}

publish() {
  if [[ "$(cat dist/cli/key.txt 2>/dev/null)" != "$key" ]]; then
    bash scripts/build.sh cli >&2
  fi
  local count i arns=()
  count="$(cat dist/cli/count.txt)"
  for (( i = 1; i <= count; i++ )); do
    log "Publishing claude-ping-cli-$i ($key part $i/$count)"
    arns+=("$(aws lambda publish-layer-version \
      --layer-name "claude-ping-cli-$i" \
      --description "$key part $i/$count" \
      --zip-file "fileb://dist/cli/layer-$i.zip" \
      --compatible-runtimes "$RUNTIME" \
      --compatible-architectures x86_64 \
      --query LayerVersionArn --output text)")
    prune "claude-ping-cli-$i"
  done
  (IFS=,; echo "${arns[*]}")
}

# Keeps the newest versions so the currently attached ones survive until the stack update
prune() {
  local old
  old="$(aws lambda list-layer-versions --layer-name "$1" \
    --query "reverse(sort_by(LayerVersions, &Version))[${KEEP_VERSIONS}:].Version" --output text)"
  for version in $old; do
    [[ "$version" == "None" ]] && continue
    log "Deleting $1:$version"
    aws lambda delete-layer-version --layer-name "$1" --version-number "$version"
  done
}

if layer_arns="$(current_arns)"; then
  log "CLI layers up to date ($key)"
else
  layer_arns="$(publish)"
fi
echo "$layer_arns"
