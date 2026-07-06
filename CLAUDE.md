# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A Claude Code **plugin** distributed via GitHub, containing a single skill,
`immure`, that sandboxes Claude Code itself behind `firejail`, restricting
filesystem access to a user-approved directory allowlist that Claude cannot
read or modify once sandboxed. Entry point is `skills/immure/SKILL.md` — read
it first; it's the orchestration logic for the whole flow (OS detection,
tool-dir detection, profile rendering, alias install, CLAUDE.md wiring) and
is not duplicated here.

## Architecture

```
.claude-plugin/
  plugin.json               # plugin metadata (name, version, author, license)
  marketplace.json          # lets users `/plugin marketplace add deglerj/immure`
skills/immure/
  SKILL.md                  # the skill's 7-step flow, run by Claude directly
  scripts/
    install-alias.sh        # only step that's a real script — installs the
                             # firejail-wrapping `claude` shell alias/function
  templates/
    claude.profile.template # static firejail hardening (noroot, caps.drop,
                             # seccomp, private-tmp/etc) + {{WHITELIST_ENTRIES}}
    sandbox-allowed-dirs.md.template   # -> ~/.claude/sandbox-allowed-dirs.md
    claude-md-snippet.md    # appended to ~/.claude/CLAUDE.md (global) so a
                             # sandboxed Claude knows to check the allowlist
                             # doc before assuming a write error is a bug
tests/
  install-alias.test.sh    # fixture-based tests for the one real script
docs/superpowers/
  specs/2026-07-05-firejail-sandbox-skill-design.md   # design rationale
  plans/2026-07-05-immure-skill.md                    # implementation plan
```

`tests/` and `docs/` are dev-only and not shipped as part of the plugin;
everything under `skills/immure/` is what gets installed.

### Key design decision: most steps are Claude-driven, not scripted

Only `install-alias.sh` is a dedicated, tested script. OS/package-manager
detection, tool-directory detection, and profile/allowlist rendering are done
by Claude directly reading `SKILL.md` and using Read/Write/Bash, not through
bespoke scripts. This is deliberate (see the "Why some steps are scripts and
some are not" section of the design doc) — rigidity in tool-dir detection or
OS classification would miss cases a fixed script/case-statement doesn't
anticipate, whereas `install-alias.sh` has real per-shell branching (bash/zsh
alias vs. fish function) and a hard idempotency requirement, which is worth
locking down and testing.

**When editing this repo:** don't "productionize" the Claude-driven steps
into scripts — that recreates the rigidity problem the design explicitly
avoids. Static/security-sensitive content (the firejail hardening lines in
`claude.profile.template`) must stay in the template files, copied verbatim —
never have Claude retype `noroot` / `caps.drop all` / `seccomp` /
`private-etc` from memory, since silent drift there is a security bug.

### Security model this code must preserve

- **Whitelist (not blacklist) mode**: enumerate the goodness (approved dirs),
  not the badness (sensitive paths to hide). This is why `SKILL.md` Step 4
  always presents a candidate list for explicit per-directory user approval
  (`AskUserQuestion`, multiSelect) — never auto-add a directory.
- **`~/.config/firejail/` is never whitelisted.** This is what makes the
  sandbox config unreachable from inside the sandbox — a structural
  property, not a prompted behavior. Any change that would cause this path
  (or its parent) to end up in the whitelist defeats the entire design.
- Existing `~/.config/firejail/claude.profile` must be shown to the user and
  confirmed before overwrite — re-running the skill must never silently
  clobber a hand-edited profile.

## Running tests

```bash
bash tests/install-alias.test.sh
```

This is the only test suite in the repo (the only scripted component). It
runs `skills/immure/scripts/install-alias.sh` against fixture `$HOME`/`$SHELL` combinations
(bash, zsh, fish, and an unrecognized shell) in a temp dir, checking both the
written output and idempotency (re-running must not duplicate the alias
line). No build step, no linter config, no other test framework — pure `bash`
+ `grep` assertions via the `check()` helper in the test file.

To add a case (e.g. a new shell), add a `check` block following the existing
per-shell pattern, using `HOME=<fake> SHELL=<path> "$SCRIPT"` and asserting
on the resulting rc file contents.
