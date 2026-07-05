#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${1:-}"

declare -A TOOL_DIRS=(
  [npm]="$HOME/.npm"
  [maven]="$HOME/.m2"
  [cargo]="$HOME/.cargo"
  [rustup]="$HOME/.rustup"
  [go]="$HOME/go"
  [pip]="$HOME/.cache/pip"
  [pipx]="$HOME/.local/share/pipx"
  [uv]="$HOME/.cache/uv"
  [gradle]="$HOME/.gradle"
)

manifest_hit() {
  local tool="$1"
  [[ -z "$PROJECT_DIR" || ! -d "$PROJECT_DIR" ]] && return 1
  case "$tool" in
    npm) [[ -f "$PROJECT_DIR/package.json" ]] ;;
    maven) [[ -f "$PROJECT_DIR/pom.xml" ]] ;;
    gradle)
      shopt -s nullglob
      local files=("$PROJECT_DIR"/build.gradle*)
      [[ ${#files[@]} -gt 0 ]]
      ;;
    cargo|rustup) [[ -f "$PROJECT_DIR/Cargo.toml" ]] ;;
    go) [[ -f "$PROJECT_DIR/go.mod" ]] ;;
    pip|pipx|uv) [[ -f "$PROJECT_DIR/requirements.txt" || -f "$PROJECT_DIR/pyproject.toml" ]] ;;
    *) return 1 ;;
  esac
}

for tool in "${!TOOL_DIRS[@]}"; do
  dir="${TOOL_DIRS[$tool]}"
  on_disk=false
  [[ -d "$dir" ]] && on_disk=true
  via_manifest=false
  manifest_hit "$tool" && via_manifest=true

  if $on_disk || $via_manifest; then
    if $on_disk && $via_manifest; then
      reason="found on disk, matches project manifest"
    elif $on_disk; then
      reason="found on disk"
    else
      reason="matches project manifest, not yet created"
    fi
    echo "$dir|$tool|$reason"
  fi
done
