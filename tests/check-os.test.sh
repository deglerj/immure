#!/usr/bin/env bash
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/../scripts/check-os.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

check_exit() {
  local desc="$1" expected="$2" os_release="$3"
  local out
  out="$(OS_RELEASE_FILE="$os_release" "$SCRIPT" 2>&1)"
  local actual=$?
  if [[ "$actual" -eq "$expected" ]]; then
    echo "PASS: $desc"
    pass=$((pass + 1))
  else
    echo "FAIL: $desc (expected exit $expected, got $actual)"
    echo "$out"
    fail=$((fail + 1))
  fi
}

check_contains() {
  local desc="$1" needle="$2" os_release="$3"
  local out
  out="$(OS_RELEASE_FILE="$os_release" "$SCRIPT" 2>&1 || true)"
  if grep -qF "$needle" <<<"$out"; then
    echo "PASS: $desc"
    pass=$((pass + 1))
  else
    echo "FAIL: $desc (expected to find '$needle')"
    echo "$out"
    fail=$((fail + 1))
  fi
}

printf 'ID=ubuntu\n' > "$TMP/ubuntu"
check_exit "ubuntu is supported (exit 0)" 0 "$TMP/ubuntu"
check_contains "ubuntu maps to apt" "PKG=apt" "$TMP/ubuntu"

printf 'ID=arch\n' > "$TMP/arch"
check_exit "arch is supported (exit 0)" 0 "$TMP/arch"
check_contains "arch maps to pacman" "PKG=pacman" "$TMP/arch"

printf 'ID=cachyos\nID_LIKE=arch\n' > "$TMP/cachyos"
check_exit "cachyos is supported (exit 0)" 0 "$TMP/cachyos"
check_contains "cachyos maps to pacman" "PKG=pacman" "$TMP/cachyos"

printf 'ID=fedora\n' > "$TMP/fedora"
check_exit "fedora is supported (exit 0)" 0 "$TMP/fedora"
check_contains "fedora maps to dnf" "PKG=dnf" "$TMP/fedora"

printf 'ID=slackware\nID_LIKE=\n' > "$TMP/slackware"
check_exit "unsupported distro aborts (exit 1)" 1 "$TMP/slackware"
check_contains "unsupported distro prints UNSUPPORTED" "UNSUPPORTED:" "$TMP/slackware"

check_exit "missing os-release file aborts (exit 1)" 1 "$TMP/does-not-exist"

echo ""
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
