# immure — Firejail Sandbox Skill Design

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
  SKILL.md                        # orchestration & interactive flow — OS detection, tool-dir
                                   # detection, and profile rendering are done by Claude directly
                                   # following SKILL.md instructions, not by dedicated scripts
                                   # (see "Why some steps are scripts and some are not" below)
  scripts/
    install-alias.sh              # detects $SHELL, appends bash/zsh alias or fish function, idempotent
  templates/
    claude.profile.template       # base firejail hardening + placeholder whitelist block
    sandbox-allowed-dirs.md.template
    claude-md-snippet.md
```

## Flow

1. **Explain firejail's security model** to the user in plain terms:
   - What it does: restricts filesystem visibility to an allowlist (whitelist mode), drops capabilities and supplementary groups (`nogroups`), blocks new privilege escalation (`nonewprivs`), uses seccomp filtering plus 32-bit syscall blocking (`seccomp.block-secondary`), narrows sockets to unix/inet/inet6 (`protocol unix,inet,inet6`), disables 3D/DVB-TV/U2F device access (`no3d`, `notv`, `nou2f`), gives a private `/tmp` and `/dev`.
   - What it does NOT do: it is not a VM (shares the host kernel), does not stop network exfiltration over TCP/IP (unix/inet/inet6 stay open in this design — only the narrower socket families like netlink/packet/bluetooth are blocked), does not stop a sufficiently novel kernel-level exploit, and is not a substitute for reviewing what Claude Code actually does.
2. **Check OS support** — Claude runs `cat /etc/os-release` and `command -v firejail` directly and classifies the result itself, following the rules in SKILL.md:
   - Debian/Ubuntu (apt) and Arch/CachyOS/Manjaro (pacman): fully supported.
   - Fedora (dnf): best-effort supported.
   - Anything else (macOS, Windows/WSL without a supported package manager, unrecognized distro): tell the user firejail isn't supported on this OS/distro and stop. No partial setup.
3. **Install firejail**. No extra packages needed for the hardening this design uses (whitelist mode, capability drop, seccomp, private-tmp/etc are all built into the base `firejail` package). Show the exact install command for the detected package manager and ask the user to confirm before running it (it needs sudo — a system-level, hard-to-reverse-ish action).
4. **Detect tool directories** — Claude checks which known toolchain state dirs actually exist on disk (`~/.npm`, `~/.m2`, `~/.cargo`, `~/.rustup`, `~/go`, `~/.cache/pip`, `~/.local/share/pipx`, `~/.cache/uv`, `~/.gradle`, and anything else it notices), and separately checks the project directory for manifest files (`package.json`, `pom.xml`, `build.gradle*`, `Cargo.toml`, `go.mod`, `requirements.txt`, `pyproject.toml`) to flag ecosystems in play even before their dir exists. Combined candidate list is presented to the user via a multi-select confirmation (accept/reject each candidate dir) before anything is written. Nothing is auto-added without the user seeing it.
5. **Generate the firejail profile** at `~/.config/firejail/claude.profile`, using **whitelist mode**. Claude reads `templates/claude.profile.template`, copies the static hardening lines verbatim (`noroot`, `nonewprivs`, `nogroups`, `caps.drop all`, default seccomp, `seccomp.block-secondary`, `protocol unix,inet,inet6`, `private-tmp`, `private-dev`, `private-etc` with the needed passthrough entries, `no3d`/`notv`/`nou2f`, no unix/inet/inet6 network restriction), and replaces the template's whitelist placeholder with one `whitelist <dir>` line per approved directory (`~/.claude` plus each approved tool dir). Same pattern for `templates/sandbox-allowed-dirs.md.template` → `~/.claude/sandbox-allowed-dirs.md`.
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

## Why some steps are scripts and some are not

Only `install-alias.sh` is a dedicated script; OS detection, tool-dir detection, and profile rendering are done by Claude directly, following instructions in `SKILL.md`, rather than through bespoke scripts. The split follows what actually needs to be deterministic and tested versus what benefits from Claude's flexibility:

- **OS/package-manager detection**: reading `/etc/os-release` and classifying it is simple enough for Claude to do reliably each time, and doing it inline is more adaptable to distro spellings/variants a fixed `case` statement wouldn't anticipate. Misclassification is low-stakes (wrong install command shown, caught immediately) — not worth a script.
- **Tool-directory detection**: a fixed array of known dirs is exactly the kind of rigidity that's worth avoiding — Claude checking for known dirs directly (and noticing ones outside the known list) covers more ecosystems than a hardcoded list ever will, and the result funnels into a user confirmation step anyway.
- **Profile/allowlist rendering**: the substitution itself (insert whitelist lines into a template) is simple enough for Claude to do directly with Read/Write. What's NOT safe to leave to Claude's judgment each run is the *static hardening content* (`noroot`, `caps.drop all`, `seccomp`, `private-etc` list) — retyping that from memory across many sessions risks silent drift. That's why the templates remain plain files Claude copies verbatim, rather than Claude free-typing a profile from scratch.
- **Shell alias installation**: this is the one step kept as a tested script. It has real per-shell branching (bash/zsh alias syntax vs. fish function syntax), a hard idempotency requirement (must not duplicate the line on repeat runs), and a side effect that silently persists and re-executes every time the user opens a shell if done wrong. That combination of branching logic + persistent side effect + easy-to-miss regression is worth locking down and testing rather than re-deriving each run.

## Error handling / edge cases

- Unsupported OS → abort immediately with a clear message, no partial state left behind (Claude stops before any writes, per SKILL.md Step 2).
- `firejail` already installed → skip install step, proceed to directory detection.
- Existing `~/.config/firejail/claude.profile` → show its contents to the user and confirm before overwriting (re-running the skill later to adjust the allowlist should not silently clobber user hand-edits).
- No tool dirs detected at all → still generate a profile with just `~/.claude` + project-dir-at-runtime whitelisted; note this to the user.
- Shell rc detection failure (unrecognized `$SHELL`) → `install-alias.sh` prints the alias line and asks the user to add it manually rather than guessing at file paths.

## Testing / verification

- `scripts/install-alias.sh` is a standalone, testable shell script — run it directly against fixture `$HOME`/`$SHELL` combinations to confirm per-shell output and idempotency.
- End-to-end manual verification: after setup, open a new shell, run `alias claude` (or `functions claude` on fish) to confirm it's registered, launch `claude` in a test project dir, confirm it can read/write the project dir and `~/.claude`, and confirm (via `firejail --whitelist=... ls ~/.config/firejail` from inside a manually-run sandboxed shell) that the profile directory is inaccessible.
