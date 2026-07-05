#!/usr/bin/env bash
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/../scripts/detect-tool-dirs.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAKE_HOME="$TMP/home"
PROJECT="$TMP/project"
mkdir -p "$FAKE_HOME/.npm" "$FAKE_HOME/.m2" "$PROJECT"

echo '{}' > "$PROJECT/package.json"
echo '' > "$PROJECT/Cargo.toml"

pass=0
fail=0

OUT="$(HOME="$FAKE_HOME" "$SCRIPT" "$PROJECT")"

check_contains() {
  local desc="$1" needle="$2"
  if grep -qF "$needle" <<<"$OUT"; then
    echo "PASS: $desc"
    pass=$((pass + 1))
  else
    echo "FAIL: $desc (expected to find '$needle' in output: $OUT)"
    fail=$((fail + 1))
  fi
}

check_not_contains() {
  local desc="$1" needle="$2"
  if grep -qF "$needle" <<<"$OUT"; then
    echo "FAIL: $desc (did not expect to find '$needle' in output: $OUT)"
    fail=$((fail + 1))
  else
    echo "PASS: $desc"
    pass=$((pass + 1))
  fi
}

check_contains "npm dir on disk + manifest match reported" "$FAKE_HOME/.npm|npm|found on disk, matches project manifest"
check_contains "maven dir on disk only reported" "$FAKE_HOME/.m2|maven|found on disk"
check_contains "cargo dir not on disk but manifest match reported" "cargo|matches project manifest, not yet created"
check_not_contains "go not mentioned (no dir, no manifest)" "|go|"

# no project dir argument at all should still work and not error
OUT2="$(HOME="$FAKE_HOME" "$SCRIPT")"
if grep -qF "$FAKE_HOME/.npm|npm|found on disk" <<<"$OUT2"; then
  echo "PASS: works with no project_dir arg"
  pass=$((pass + 1))
else
  echo "FAIL: works with no project_dir arg (output: $OUT2)"
  fail=$((fail + 1))
fi

echo ""
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
