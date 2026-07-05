#!/usr/bin/env bash
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/../scripts/install-alias.sh"
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

# bash
FAKE_HOME="$TMP/bash-home"
mkdir -p "$FAKE_HOME"
OUT="$(HOME="$FAKE_HOME" SHELL=/bin/bash "$SCRIPT")"
check "bash: prints WROTE" grep -qF "WROTE: $FAKE_HOME/.bashrc" <<<"$OUT"
check "bash: rc file has alias" grep -q "alias claude=" "$FAKE_HOME/.bashrc"
check "bash: rc file references firejail" grep -q "CLAUDE_SANDBOXED=firejail" "$FAKE_HOME/.bashrc"

# re-run: should be idempotent
OUT2="$(HOME="$FAKE_HOME" SHELL=/bin/bash "$SCRIPT")"
check "bash: second run reports ALREADY_PRESENT" grep -qF "ALREADY_PRESENT: $FAKE_HOME/.bashrc" <<<"$OUT2"
LINES_BEFORE=$(grep -c "CLAUDE_SANDBOXED=firejail" "$FAKE_HOME/.bashrc")
check "bash: second run does not duplicate the line" [ "$LINES_BEFORE" -eq 1 ]

# zsh
FAKE_HOME_ZSH="$TMP/zsh-home"
mkdir -p "$FAKE_HOME_ZSH"
OUT3="$(HOME="$FAKE_HOME_ZSH" SHELL=/usr/bin/zsh "$SCRIPT")"
check "zsh: prints WROTE" grep -qF "WROTE: $FAKE_HOME_ZSH/.zshrc" <<<"$OUT3"
check "zsh: rc file has alias" grep -q "alias claude=" "$FAKE_HOME_ZSH/.zshrc"

# fish
FAKE_HOME_FISH="$TMP/fish-home"
mkdir -p "$FAKE_HOME_FISH"
OUT4="$(HOME="$FAKE_HOME_FISH" SHELL=/usr/bin/fish "$SCRIPT")"
check "fish: prints WROTE" grep -qF "WROTE: $FAKE_HOME_FISH/.config/fish/config.fish" <<<"$OUT4"
check "fish: config has function claude" grep -q "function claude" "$FAKE_HOME_FISH/.config/fish/config.fish"

# unknown shell
FAKE_HOME_UNK="$TMP/unk-home"
mkdir -p "$FAKE_HOME_UNK"
set +e
OUT5="$(HOME="$FAKE_HOME_UNK" SHELL=/bin/tcsh "$SCRIPT" 2>&1)"
CODE=$?
set -e
check "unknown shell exits 1" [ "$CODE" -eq 1 ]
check "unknown shell prints UNKNOWN_SHELL" grep -qF "UNKNOWN_SHELL:" <<<"$OUT5"

echo ""
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
