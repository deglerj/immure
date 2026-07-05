#!/usr/bin/env bash
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/../scripts/render-config.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

check() {
  local desc="$1"
  shift
  if "$@"; then
    echo "PASS: $desc"
    pass=$((pass + 1))
  else
    echo "FAIL: $desc"
    fail=$((fail + 1))
  fi
}

PROFILE_OUT="$TMP/claude.profile"
DIRS_OUT="$TMP/sandbox-allowed-dirs.md"

"$SCRIPT" \
  "$DIR/../templates/claude.profile.template" "$PROFILE_OUT" \
  "$DIR/../templates/sandbox-allowed-dirs.md.template" "$DIRS_OUT" \
  "/home/test/.claude" "/home/test/.npm"

check "profile output exists" [ -f "$PROFILE_OUT" ]
check "profile has first whitelist entry" grep -q "whitelist /home/test/.claude" "$PROFILE_OUT"
check "profile has second whitelist entry" grep -q "whitelist /home/test/.npm" "$PROFILE_OUT"
check "profile no longer has the raw token" bash -c "! grep -qF '{{WHITELIST_ENTRIES}}' '$PROFILE_OUT'"
check "profile kept the static hardening lines" grep -q "caps.drop all" "$PROFILE_OUT"

check "dirs output exists" [ -f "$DIRS_OUT" ]
check "dirs doc lists first dir" grep -qF '`/home/test/.claude`' "$DIRS_OUT"
check "dirs doc lists second dir" grep -qF '`/home/test/.npm`' "$DIRS_OUT"
check "dirs doc no longer has the raw token" bash -c "! grep -qF '{{ALLOWLIST_TABLE}}' '$DIRS_OUT'"

set +e
"$SCRIPT" "$DIR/../templates/claude.profile.template" "$PROFILE_OUT" >/dev/null 2>&1
CODE=$?
set -e
check "too few args exits 1" [ "$CODE" -eq 1 ]

echo ""
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
