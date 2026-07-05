# immure Skill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the `immure` Claude Code skill: a `SKILL.md` plus supporting shell scripts and templates that set up a firejail sandbox around Claude Code, restricting its filesystem access to a user-approved directory allowlist that Claude cannot itself modify.

**Architecture:** Three small, independently-testable bash scripts (`check-os.sh`, `detect-tool-dirs.sh`, `install-alias.sh`, `render-config.sh`) each do one deterministic job and are covered by a hand-rolled assertion-style test script (no test framework — plain bash + `grep`/exit-code checks). `SKILL.md` is the orchestration layer: prose instructions telling the Claude agent which script to run when, how to interpret its output, and when to pause for user confirmation (`AskUserQuestion` for directory approval, explicit confirmation before any `sudo` install or profile overwrite). Templates hold the static file content (firejail profile, allowlist doc, CLAUDE.md snippet) with `{{TOKEN}}` placeholders substituted by `render-config.sh`.

**Tech Stack:** bash (scripts + tests), firejail (the sandbox tool being configured), Claude Code skill format (`SKILL.md` with YAML frontmatter).

## Global Constraints

- Supported OS: Debian/Ubuntu (apt) and Arch/CachyOS/Manjaro (pacman) — full support. Fedora (dnf) — best-effort. Anything else: abort immediately with a clear message, no partial state written.
- Filesystem restriction uses firejail **whitelist mode only** — no blacklist-of-sensitive-dirs approach.
- **Full network access is kept** — no network whitelisting/restriction in this version.
- No standalone wrapper script file — the `claude` launcher is a shell alias (bash/zsh) or function (fish), appended to the user's existing shell rc file.
- `~/.config/firejail/` must never be added to the whitelist — this is what makes the sandbox config unreachable from inside the sandbox.
- `~/.claude/CLAUDE.md` gets only a short pointer block; the full directory allowlist lives in `~/.claude/sandbox-allowed-dirs.md`, read by Claude on demand only.
- Re-running the setup must never silently overwrite an existing `~/.config/firejail/claude.profile` without showing the user what would change and confirming first.
- Any `sudo` command (installing firejail) requires explicit user confirmation before running.

---

## Task 1: `check-os.sh` — OS/package-manager/firejail detection

**Files:**
- Create: `scripts/check-os.sh`
- Test: `tests/check-os.test.sh`

**Interfaces:**
- Produces: `scripts/check-os.sh [no args]`. Reads `OS_RELEASE_FILE` env var (default `/etc/os-release`). On a supported distro: prints `PKG=<apt|pacman|dnf>` and `FIREJAIL_INSTALLED=<yes|no>` to stdout, exits 0. On an unsupported distro: prints a line starting with `UNSUPPORTED:` to stderr, exits 1. On missing `OS_RELEASE_FILE`: prints `UNSUPPORTED:` to stderr, exits 1.

- [ ] **Step 1: Write the failing test**

Create `tests/check-os.test.sh`:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `chmod +x tests/check-os.test.sh && bash tests/check-os.test.sh`
Expected: FAIL — `scripts/check-os.sh: No such file or directory` (or similar), most/all checks report FAIL since the script doesn't exist yet.

- [ ] **Step 3: Write minimal implementation**

Create `scripts/check-os.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

OS_RELEASE_FILE="${OS_RELEASE_FILE:-/etc/os-release}"

if [[ ! -f "$OS_RELEASE_FILE" ]]; then
  echo "UNSUPPORTED: cannot find $OS_RELEASE_FILE to detect distro. immure only supports Linux distros exposing /etc/os-release. Aborting." >&2
  exit 1
fi

ID=""
ID_LIKE=""
# shellcheck disable=SC1090
source "$OS_RELEASE_FILE"

combined="$ID $ID_LIKE"
PKG=""
case "$combined" in
  *debian*|*ubuntu*) PKG="apt" ;;
  *arch*|*cachyos*|*manjaro*) PKG="pacman" ;;
  *fedora*) PKG="dnf" ;;
  *)
    echo "UNSUPPORTED: distro '$ID' (like: '$ID_LIKE') is not supported by immure. Supported: Debian/Ubuntu (apt), Arch/CachyOS/Manjaro (pacman), Fedora (dnf, best-effort). Aborting." >&2
    exit 1
    ;;
esac

echo "PKG=$PKG"

if command -v firejail >/dev/null 2>&1; then
  echo "FIREJAIL_INSTALLED=yes"
else
  echo "FIREJAIL_INSTALLED=no"
fi
```

Run: `chmod +x scripts/check-os.sh`

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/check-os.test.sh`
Expected: `0 failed` on the last line, all `PASS:` lines.

- [ ] **Step 5: Commit**

```bash
git add scripts/check-os.sh tests/check-os.test.sh
git commit -m "Add check-os.sh: distro/package-manager/firejail detection"
```

---

## Task 2: `detect-tool-dirs.sh` — candidate directory detection

**Files:**
- Create: `scripts/detect-tool-dirs.sh`
- Test: `tests/detect-tool-dirs.test.sh`

**Interfaces:**
- Produces: `scripts/detect-tool-dirs.sh [project_dir]`. Reads `$HOME`. Prints zero or more lines `<dir>|<tool>|<reason>` to stdout, one per detected candidate. `reason` is one of `found on disk`, `matches project manifest, not yet created`, or `found on disk, matches project manifest`. Never fails (exit 0 always, even with no candidates or no `project_dir` arg).

- [ ] **Step 1: Write the failing test**

Create `tests/detect-tool-dirs.test.sh`:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `chmod +x tests/detect-tool-dirs.test.sh && bash tests/detect-tool-dirs.test.sh`
Expected: FAIL — script doesn't exist yet, all checks FAIL.

- [ ] **Step 3: Write minimal implementation**

Create `scripts/detect-tool-dirs.sh`:

```bash
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
```

Run: `chmod +x scripts/detect-tool-dirs.sh`

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/detect-tool-dirs.test.sh`
Expected: `0 failed` on the last line.

- [ ] **Step 5: Commit**

```bash
git add scripts/detect-tool-dirs.sh tests/detect-tool-dirs.test.sh
git commit -m "Add detect-tool-dirs.sh: candidate whitelist dir detection"
```

---

## Task 3: `install-alias.sh` — shell alias/function installer

**Files:**
- Create: `scripts/install-alias.sh`
- Test: `tests/install-alias.test.sh`

**Interfaces:**
- Produces: `scripts/install-alias.sh [no args]`. Reads `$HOME` and `$SHELL`. On bash: appends an `alias claude=...` line to `$HOME/.bashrc`. On zsh: same line to `$HOME/.zshrc`. On fish: appends a `function claude ... end` block to `$HOME/.config/fish/config.fish` (creating the parent dir if needed). Prints `WROTE: <rc-file>` on stdout and exits 0 on first install. If the rc file already contains `CLAUDE_SANDBOXED=firejail`, prints `ALREADY_PRESENT: <rc-file>` and exits 0 without modifying the file. On an unrecognized `$SHELL`, prints `UNKNOWN_SHELL: ...` to stderr followed by the alias line to copy manually, and exits 1.

- [ ] **Step 1: Write the failing test**

Create `tests/install-alias.test.sh`:

```bash
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
check "bash: second run does not duplicate the line" [[ "$LINES_BEFORE" -eq 1 ]]

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
check "unknown shell exits 1" [[ "$CODE" -eq 1 ]]
check "unknown shell prints UNKNOWN_SHELL" grep -qF "UNKNOWN_SHELL:" <<<"$OUT5"

echo ""
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `chmod +x tests/install-alias.test.sh && bash tests/install-alias.test.sh`
Expected: FAIL — script doesn't exist yet.

- [ ] **Step 3: Write minimal implementation**

Create `scripts/install-alias.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

SHELL_NAME="$(basename "${SHELL:-}")"

BASH_ZSH_LINE="alias claude='CLAUDE_SANDBOXED=firejail firejail --whitelist=\"\$PWD\" --profile=\$HOME/.config/firejail/claude.profile claude'"

FISH_BLOCK='function claude
    env CLAUDE_SANDBOXED=firejail firejail --whitelist="$PWD" --profile=$HOME/.config/firejail/claude.profile claude $argv
end'

case "$SHELL_NAME" in
  bash)
    RC="$HOME/.bashrc"
    LINE="$BASH_ZSH_LINE"
    ;;
  zsh)
    RC="$HOME/.zshrc"
    LINE="$BASH_ZSH_LINE"
    ;;
  fish)
    RC="$HOME/.config/fish/config.fish"
    LINE="$FISH_BLOCK"
    ;;
  *)
    echo "UNKNOWN_SHELL: could not detect a supported shell rc file for '$SHELL_NAME'. Add this to your shell config manually:" >&2
    echo "$BASH_ZSH_LINE" >&2
    exit 1
    ;;
esac

if [[ -f "$RC" ]] && grep -q "CLAUDE_SANDBOXED=firejail" "$RC"; then
  echo "ALREADY_PRESENT: $RC"
  exit 0
fi

mkdir -p "$(dirname "$RC")"
{
  echo ""
  echo "# added by immure skill"
  echo "$LINE"
} >> "$RC"

echo "WROTE: $RC"
```

Run: `chmod +x scripts/install-alias.sh`

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/install-alias.test.sh`
Expected: `0 failed` on the last line.

- [ ] **Step 5: Commit**

```bash
git add scripts/install-alias.sh tests/install-alias.test.sh
git commit -m "Add install-alias.sh: bash/zsh/fish claude sandbox alias installer"
```

---

## Task 4: Templates + `render-config.sh`

**Files:**
- Create: `templates/claude.profile.template`
- Create: `templates/sandbox-allowed-dirs.md.template`
- Create: `templates/claude-md-snippet.md`
- Create: `scripts/render-config.sh`
- Test: `tests/render-config.test.sh`

**Interfaces:**
- Produces: `scripts/render-config.sh <profile_template> <profile_out> <dirs_template> <dirs_out> <dir> [<dir> ...]`. Substitutes `{{WHITELIST_ENTRIES}}` in `profile_template` with one `whitelist <dir>` line per given dir, writes to `profile_out`. Substitutes `{{ALLOWLIST_TABLE}}` in `dirs_template` with one `` - `<dir>` `` line per given dir, writes to `dirs_out`. Prints `Wrote <profile_out> and <dirs_out>` and exits 0. Requires at least one dir argument (exits 1 with a usage message if fewer than 5 args given, since the two output/template pairs plus at least one dir means 5 args minimum).

- [ ] **Step 1: Write the failing test**

Create `templates/claude.profile.template` (needed by the test, written now so the test is a true reflection of production content — this file is data, not code under test, so no separate TDD cycle applies to it):

```
# immure - generated firejail profile for Claude Code.
# Do not hand-edit the whitelist block below; re-run the immure skill to
# regenerate it. Everything else in this file is safe to hand-tune.

noroot
caps.drop all
seccomp
private-tmp
private-etc passwd,group,hostname,hosts,resolv.conf,ssl,ca-certificates,nsswitch.conf,localtime,machine-id

{{WHITELIST_ENTRIES}}
```

Create `templates/sandbox-allowed-dirs.md.template`:

```
# Sandbox allowed directories

Claude Code is running inside a firejail sandbox (whitelist mode). Only the
directories listed below — plus the current project directory, added
automatically each time `claude` is launched — are visible on disk.
Everything else under your home directory is hidden, not just read-only.

{{ALLOWLIST_TABLE}}

If you need a directory that isn't listed here, don't try to work around
it: ask the user to add it. They edit `~/.config/firejail/claude.profile`,
add a line `whitelist <path>`, then start a new `claude` session (the
profile is read once, at sandbox startup) — or just re-run the immure
skill, which re-detects candidates and rewrites this file too.
```

Create `templates/claude-md-snippet.md`:

```
## Sandbox awareness (immure / firejail)

You may be running inside a firejail sandbox (`$CLAUDE_SANDBOXED=firejail`
is set when so). Filesystem access is a fixed allowlist you cannot change
from inside the sandbox. If you hit a permission/write error that looks
like a sandbox restriction (not a normal permission error), read
`~/.claude/sandbox-allowed-dirs.md` for the current allowlist before
retrying anything, and ask the user to add a directory — don't try to
work around it yourself.
```

Create `tests/render-config.test.sh`:

```bash
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

check "profile output exists" [[ -f "$PROFILE_OUT" ]]
check "profile has first whitelist entry" grep -q "whitelist /home/test/.claude" "$PROFILE_OUT"
check "profile has second whitelist entry" grep -q "whitelist /home/test/.npm" "$PROFILE_OUT"
check "profile no longer has the raw token" bash -c "! grep -qF '{{WHITELIST_ENTRIES}}' '$PROFILE_OUT'"
check "profile kept the static hardening lines" grep -q "caps.drop all" "$PROFILE_OUT"

check "dirs output exists" [[ -f "$DIRS_OUT" ]]
check "dirs doc lists first dir" grep -qF '`/home/test/.claude`' "$DIRS_OUT"
check "dirs doc lists second dir" grep -qF '`/home/test/.npm`' "$DIRS_OUT"
check "dirs doc no longer has the raw token" bash -c "! grep -qF '{{ALLOWLIST_TABLE}}' '$DIRS_OUT'"

set +e
"$SCRIPT" "$DIR/../templates/claude.profile.template" "$PROFILE_OUT" >/dev/null 2>&1
CODE=$?
set -e
check "too few args exits 1" [[ "$CODE" -eq 1 ]]

echo ""
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `chmod +x tests/render-config.test.sh && bash tests/render-config.test.sh`
Expected: FAIL — `scripts/render-config.sh` doesn't exist yet.

- [ ] **Step 3: Write minimal implementation**

Create `scripts/render-config.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 5 ]]; then
  echo "usage: render-config.sh <profile_template> <profile_out> <dirs_template> <dirs_out> <dir> [<dir> ...]" >&2
  exit 1
fi

PROFILE_TEMPLATE="$1"
PROFILE_OUT="$2"
DIRS_TEMPLATE="$3"
DIRS_OUT="$4"
shift 4
DIRS=("$@")

whitelist_lines=""
table_lines=""
for dir in "${DIRS[@]}"; do
  whitelist_lines+="whitelist ${dir}"$'\n'
  table_lines+="- \`${dir}\`"$'\n'
done

# ponytail: plain gsub, doesn't escape awk-special chars (&, backslash) in
# dir paths. Fine for real-world home/tool dirs; revisit if a whitelisted
# path ever contains one.
awk -v repl="$whitelist_lines" '{gsub(/\{\{WHITELIST_ENTRIES\}\}/, repl); print}' "$PROFILE_TEMPLATE" > "$PROFILE_OUT"
awk -v repl="$table_lines" '{gsub(/\{\{ALLOWLIST_TABLE\}\}/, repl); print}' "$DIRS_TEMPLATE" > "$DIRS_OUT"

echo "Wrote $PROFILE_OUT and $DIRS_OUT"
```

Run: `chmod +x scripts/render-config.sh`

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/render-config.test.sh`
Expected: `0 failed` on the last line.

- [ ] **Step 5: Commit**

```bash
git add templates/ scripts/render-config.sh tests/render-config.test.sh
git commit -m "Add config templates and render-config.sh renderer"
```

---

## Task 5: `SKILL.md` — orchestration

**Files:**
- Create: `SKILL.md`

**Interfaces:**
- Consumes:
  - `scripts/check-os.sh` → stdout `PKG=...` / `FIREJAIL_INSTALLED=...`, stderr `UNSUPPORTED:` + exit 1 on unsupported OS.
  - `scripts/detect-tool-dirs.sh <project_dir>` → stdout lines `<dir>|<tool>|<reason>`.
  - `scripts/install-alias.sh` → stdout `WROTE: <rc>` / `ALREADY_PRESENT: <rc>`, stderr `UNKNOWN_SHELL:` + exit 1.
  - `scripts/render-config.sh <profile_template> <profile_out> <dirs_template> <dirs_out> <dir>...` → writes both output files, prints `Wrote ...`.
  - `templates/claude-md-snippet.md` — static content to append to `$HOME/.claude/CLAUDE.md`.

- [ ] **Step 1: Write `SKILL.md`**

Create `SKILL.md`:

```markdown
---
name: immure
description: Set up or update a firejail sandbox that Claude Code runs inside, restricting its filesystem access to a user-approved directory allowlist that Claude cannot itself modify. Use when the user asks to sandbox Claude Code, run Claude Code inside firejail, restrict Claude's filesystem access, or mentions "immure". Also use when Claude Code is already sandboxed and hits a permission/write error that looks like a sandbox restriction (check `~/.claude/sandbox-allowed-dirs.md` first — this skill is how a new directory gets added).
---

# immure

Puts Claude Code itself behind a firejail sandbox: filesystem access is
restricted to a directory allowlist the user approves, and the sandbox
config lives outside that allowlist so Claude cannot read or change it
once sandboxed.

## When to use this

- User asks to sandbox Claude Code, run it inside firejail, or restrict
  its filesystem access.
- The sandbox is already set up and the user wants to add a directory
  (e.g. Claude reported a write error that looks like a sandbox
  restriction — see `~/.claude/sandbox-allowed-dirs.md`).

## Step 1: Explain firejail's security model

Before touching anything, tell the user, in plain terms:

- **What firejail does here:** restricts filesystem visibility to an
  allowlist (whitelist mode) — anything not listed is hidden, not just
  read-only; drops Linux capabilities (`caps.drop all`); blocks privilege
  escalation (`noroot`); applies the default seccomp filter; gives Claude
  Code a private `/tmp`.
- **What it does NOT do:** it is not a VM — it shares the host kernel, so
  a kernel-level exploit escapes it; it does not restrict network access
  in this setup (full network stays open — npm/pip/cargo/git/the
  Anthropic API all need it); it is not a substitute for reviewing what
  Claude Code actually does.

## Step 2: Check OS support

Run:

```bash
bash scripts/check-os.sh
```

- Exit 0 → prints `PKG=<apt|pacman|dnf>` and `FIREJAIL_INSTALLED=<yes|no>`.
  Continue to Step 3.
- Exit 1 → distro unsupported. Show the script's stderr message to the
  user and **stop here**. Do not run any further steps.

## Step 3: Install firejail if needed

If `FIREJAIL_INSTALLED=no`, show the user the install command for their
`PKG` and get explicit confirmation before running it (it needs sudo):

- `apt` → `sudo apt install firejail`
- `pacman` → `sudo pacman -S firejail`
- `dnf` → `sudo dnf install firejail`

Never run the sudo command without the user confirming first.

## Step 4: Detect candidate directories

Ask the user which project directory they primarily work in if it isn't
already obvious from context, then run:

```bash
bash scripts/detect-tool-dirs.sh /path/to/project
```

Output is pipe-delimited lines `<dir>|<tool>|<reason>`. Parse this into a
candidate list. Always add `$HOME/.claude` to the list unconditionally —
the script does not emit it.

Present the full candidate list to the user with the `AskUserQuestion`
tool (multiSelect) so each directory is explicitly approved or rejected
before anything is written to disk. Do not skip this confirmation, and
do not add any directory the user didn't approve.

## Step 5: Generate the profile and allowlist doc

Take the user-approved absolute directory paths (this always includes
`$HOME/.claude`) and run:

```bash
bash scripts/render-config.sh \
  templates/claude.profile.template "$HOME/.config/firejail/claude.profile" \
  templates/sandbox-allowed-dirs.md.template "$HOME/.claude/sandbox-allowed-dirs.md" \
  <approved-dir-1> <approved-dir-2> ...
```

If `$HOME/.config/firejail/claude.profile` already exists, show its
current contents to the user and get confirmation before overwriting —
re-running this skill must never silently clobber a hand-edited profile.

## Step 6: Install the shell alias

Run:

```bash
bash scripts/install-alias.sh
```

- `WROTE: <rc-file>` → tell the user to open a new shell (or `source` the
  rc file) for the alias/function to take effect.
- `ALREADY_PRESENT: <rc-file>` → nothing to do.
- Exit 1 with `UNKNOWN_SHELL: ...` → show the user the alias/function
  line from stderr and ask them to add it to their shell config by hand.

## Step 7: Wire up sandbox awareness in CLAUDE.md

Check whether `$HOME/.claude/CLAUDE.md` already contains the line
`## Sandbox awareness (immure / firejail)`. If it does, skip this step —
don't duplicate the block. Otherwise, append the full contents of
`templates/claude-md-snippet.md` to `$HOME/.claude/CLAUDE.md` (creating
the file first if it doesn't exist).

## Done

Summarize for the user: which directories are now whitelisted, where the
profile lives (`~/.config/firejail/claude.profile`), that the alias/
function is active in new shells, and that adding another directory
later means either re-running this skill or hand-editing the profile
(`whitelist <path>` line) themselves — Claude cannot do this from inside
the sandbox by design.
```

- [ ] **Step 2: Sanity-check the referenced paths exist**

Run:

```bash
test -x scripts/check-os.sh && test -x scripts/detect-tool-dirs.sh && test -x scripts/install-alias.sh && test -x scripts/render-config.sh && test -f templates/claude.profile.template && test -f templates/sandbox-allowed-dirs.md.template && test -f templates/claude-md-snippet.md && echo ALL_PRESENT
```

Expected: `ALL_PRESENT` printed, no errors.

- [ ] **Step 3: Commit**

```bash
git add SKILL.md
git commit -m "Add SKILL.md orchestrating the immure sandbox setup flow"
```

---

## Task 6: End-to-end manual verification

**Files:** none created — this task exercises what Tasks 1–5 built, on a real machine with firejail installed.

- [ ] **Step 1: Run all four test scripts together**

```bash
bash tests/check-os.test.sh && bash tests/detect-tool-dirs.test.sh && bash tests/install-alias.test.sh && bash tests/render-config.test.sh
```

Expected: every script prints `0 failed` on its last line.

- [ ] **Step 2: Dry-run the real OS check**

```bash
bash scripts/check-os.sh
```

Expected on this machine (CachyOS/Arch): `PKG=pacman` and either
`FIREJAIL_INSTALLED=yes` or `FIREJAIL_INSTALLED=no`, exit 0.

- [ ] **Step 3: Render a real profile into a scratch location and inspect it**

```bash
mkdir -p /tmp/immure-verify
bash scripts/render-config.sh \
  templates/claude.profile.template /tmp/immure-verify/claude.profile \
  templates/sandbox-allowed-dirs.md.template /tmp/immure-verify/sandbox-allowed-dirs.md \
  "$HOME/.claude" "$HOME/.npm"
cat /tmp/immure-verify/claude.profile
cat /tmp/immure-verify/sandbox-allowed-dirs.md
```

Expected: both files show the whitelist entries for `$HOME/.claude` and
`$HOME/.npm`, no `{{...}}` tokens remain, hardening lines (`noroot`,
`caps.drop all`, etc.) are present in the profile.

- [ ] **Step 4: Confirm the sandbox config directory is actually invisible under whitelist mode**

(Requires firejail installed.) Run a throwaway sandboxed shell using the
rendered scratch profile, and confirm `~/.config/firejail` is not visible:

```bash
firejail --whitelist="$HOME/.claude" --whitelist="$HOME/.npm" --noprofile bash -c 'ls ~/.config/firejail 2>&1; ls ~/.claude >/dev/null && echo CLAUDE_DIR_OK'
```

Expected: the `ls ~/.config/firejail` line errors (`No such file or
directory` or similar — the path is not visible), and `CLAUDE_DIR_OK` is
printed (the whitelisted dir is visible).

- [ ] **Step 5: Clean up scratch files**

```bash
rm -rf /tmp/immure-verify
```

No commit for this task — it's verification only, no files changed.
