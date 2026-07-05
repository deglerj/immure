# Firejail Sandbox Skill — Design

Date: 2026-07-05

## Purpose

A Claude Code skill that puts Claude Code itself behind a `firejail` sandbox, restricting its filesystem access to a user-approved allowlist of directories, and making the sandbox config unreachable/unwritable from inside the sandbox so Claude cannot loosen its own restrictions.

## Non-goals

- Not a VM / not full isolation against a kernel exploit or malicious binary.
- No network whitelisting — full network access is kept (npm/pip/cargo registries, git remotes, Anthropic API all need broad outbound access; restricting this is high-effort/fragile and out of scope for v1).
- No GUI tooling (firetools).
- No per-project committed sandbox config — one global profile + shell alias.
- No automatic remediation — if Claude hits a sandbox wall, it surfaces the problem and asks the user to fix the config; it never attempts to edit the config itself (and structurally cannot, per the security design below).

## Components

```
immure/
  SKILL.md                        # orchestration & interactive flow
  scripts/
    check-os.sh                   # detect distro + firejail availability; exit non-zero with message if unsupported
    detect-tool-dirs.sh           # scan $HOME for known toolchain dirs + scan a given project dir for manifest files
  templates/
    claude.profile.template       # base firejail hardening + placeholder whitelist block
    sandbox-allowed-dirs.md.template
    claude-md-snippet.md
```

## Flow

1. **Explain firejail's security model** to the user in plain terms:
   - What it does: restricts filesystem visibility to an allowlist (whitelist mode), drops capabilities, blocks new privilege escalation, uses seccomp filtering, gives a private `/tmp`.
   - What it does NOT do: it is not a VM (shares the host kernel), does not stop network exfiltration (network is left open in this design), does not stop a sufficiently novel kernel-level exploit, and is not a substitute for reviewing what Claude Code actually does.
2. **Check OS support** via `scripts/check-os.sh`:
   - Debian/Ubuntu (apt) and Arch/CachyOS (pacman): fully supported.
   - Fedora (dnf): best-effort supported.
   - Anything else (macOS, Windows/WSL without a supported package manager, unrecognized distro): print "firejail is not supported on this OS/distro — aborting" and stop. No partial setup.
3. **Install firejail** (+ recommended companions, e.g. `firejail-profiles` where packaged separately). Show the exact install command for the detected package manager and ask the user to confirm before running it (it needs sudo — a system-level, hard-to-reverse-ish action).
4. **Detect tool directories**:
   - `scripts/detect-tool-dirs.sh` scans `$HOME` for known toolchain state dirs that actually exist on disk: `~/.npm`, `~/.m2`, `~/.cargo`, `~/.rustup`, `~/go`, `~/.cache/pip`, `~/.local/share/pipx`, `~/.cache/uv`, `~/.gradle`, etc.
   - It also accepts a project directory argument and scans it for manifest files (`package.json`, `pom.xml`, `build.gradle*`, `Cargo.toml`, `go.mod`, `requirements.txt`, `pyproject.toml`) to flag which ecosystems are actually in play.
   - Combined candidate list is presented to the user via a multi-select confirmation (accept/reject each candidate dir) before anything is written. Nothing is auto-added without the user seeing it.
5. **Generate the firejail profile** at `~/.config/firejail/claude.profile`, using **whitelist mode**:
   - Baseline hardening: `noroot`, `caps.drop all`, default seccomp, `private-tmp`, `private-etc` (with the needed passthrough entries for resolving binaries/certs), no network restriction.
   - `whitelist ~/.claude`
   - `whitelist <each approved tool dir>`
   - Project directory is deliberately **not** baked into this static file (see step 6).
   - `~/.config/firejail/` itself is never whitelisted — from inside the sandbox this path (and its sibling `claude.profile` file) does not exist, so Claude cannot read or write it. `/etc/firejail/` (system-wide profiles) is untouched by this flow entirely.
6. **Shell alias**, appended to the user's shell rc (bash/zsh/fish, detected via `$SHELL`):
   ```sh
   alias claude='CLAUDE_SANDBOXED=firejail firejail --whitelist="$PWD" --profile=~/.config/firejail/claude.profile claude'
   ```
   `--whitelist="$PWD"` is what makes the sandbox track whatever project directory `claude` is launched from, without needing to regenerate the static profile per project.
7. **Sandbox awareness for Claude**:
   - Append a short block to `~/.claude/CLAUDE.md` (global) pointing at the detail file — kept short deliberately so it doesn't bloat context on every session:
     > You may be running inside a firejail sandbox (`$CLAUDE_SANDBOXED=firejail` is set when so). Filesystem access is a fixed allowlist you cannot change. If you hit permission/write errors that look like sandbox restriction (not a normal permission error), read `~/.claude/sandbox-allowed-dirs.md` for the current allowlist before retrying anything, and ask the user to add a directory — don't try to work around it yourself.
   - Write the actual allowlist + short rationale for each entry to `~/.claude/sandbox-allowed-dirs.md`, read by Claude only on demand.

## Why whitelist mode, not blacklist

Firejail's `--whitelist=<dir>` puts that whole top-level tree (e.g. the rest of `$HOME`) into a hidden/empty state except for what's explicitly whitelisted. This directly satisfies "limit Claude to directories it actually needs" — it is an enumerate-the-goodness model. Blacklisting specific sensitive paths (`~/.ssh`, `~/.aws`, browser profile dirs, etc.) is the weaker enumerate-the-badness approach and was rejected because the list of "sensitive things under home" is open-ended and easy to miss entries for.

## Why Claude cannot modify its own sandbox config

This is a structural property of whitelist mode, not a prompted behavior: `~/.config/firejail/` is not in the whitelist, so the mount namespace inside the sandbox simply does not expose that path. Claude has no read or write access to `claude.profile` regardless of what it's asked to do or tries to do. `/etc/firejail/` (root-owned system profiles) is unaffected by anything in this flow, since the flow only writes user-level config.

## Error handling / edge cases

- Unsupported OS → abort immediately with a clear message, no partial state left behind (script exits before any writes).
- `firejail` already installed → skip install step, proceed to profile generation.
- Existing `~/.config/firejail/claude.profile` → show a diff/summary of what would change and confirm before overwriting (re-running the skill later to adjust the allowlist should not silently clobber user hand-edits).
- No tool dirs detected at all → still generate a profile with just `~/.claude` + project-dir-at-runtime whitelisted; note this to the user.
- Shell rc detection failure (unrecognized `$SHELL`) → print the alias line and ask the user to add it manually rather than guessing at file paths.

## Testing / verification

- `scripts/check-os.sh` and `scripts/detect-tool-dirs.sh` are standalone, testable shell scripts — run them directly against a few `$HOME` fixtures / fake `/etc/os-release` files to confirm detection logic and exit codes.
- End-to-end manual verification: after setup, open a new shell, run `alias claude` to confirm it's registered, launch `claude` in a test project dir, confirm it can read/write the project dir and `~/.claude`, and confirm (via `firejail --whitelist=... ls ~/.config/firejail` from inside a manually-run sandboxed shell) that the profile directory is inaccessible.
