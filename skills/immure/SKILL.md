---
name: immure
description: Set up or update a firejail sandbox that Claude Code runs inside, restricting its filesystem access to a user-approved directory allowlist that Claude cannot itself modify. Use when the user asks to sandbox Claude Code, run Claude Code inside firejail, restrict Claude's filesystem access, or mentions "immure". Also use when Claude Code is already sandboxed and hits a permission/write error, or a tool (git, gh, etc.) reports missing auth/config that's actually it being unable to reach its config files, that looks like a sandbox restriction (check `~/.claude/sandbox-allowed-dirs.md` first — this skill is how a new directory gets added).
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
  read-only; drops Linux capabilities (`caps.drop all`) and supplementary
  groups (`nogroups`); blocks becoming root (`noroot`) and any other
  privilege gain (`nonewprivs`); applies the default seccomp filter plus
  32-bit syscall blocking (`seccomp.block-secondary`); restricts sockets to
  unix/inet/inet6 (`protocol unix,inet,inet6`, dropping netlink/packet/
  bluetooth); disables 3D/DVB-TV/U2F device access (`no3d`, `notv`,
  `nou2f`); gives Claude Code a private `/tmp` and `/dev`.
- **What it does NOT do:** it is not a VM — it shares the host kernel, so
  a kernel-level exploit escapes it; it does not restrict TCP/IP network
  access in this setup (npm/pip/cargo/git/the Anthropic API all need it —
  only the socket *families* are narrowed, not blocked); it is not a
  substitute for reviewing what Claude Code actually does.

## Step 2: Check OS support

Run:

```bash
cat /etc/os-release
command -v firejail
```

Classify the distro from `ID` and `ID_LIKE` in `/etc/os-release`:

- `debian` or `ubuntu` (in `ID` or `ID_LIKE`) → package manager `apt`.
- `arch`, `cachyos`, or `manjaro` → package manager `pacman`.
- `fedora` → package manager `dnf` (best-effort support).
- Anything else, or `/etc/os-release` doesn't exist → **unsupported.**
  Tell the user immure doesn't support this OS/distro and **stop here**.
  Do not run any further steps, don't write anything.

If `command -v firejail` found nothing, firejail isn't installed yet —
continue to Step 3. If it printed a path, firejail is already installed —
skip Step 3 and go to Step 4.

## Step 3: Install firejail if needed

Show the user the install command for the package manager identified in
Step 2 and get explicit confirmation before running it (it needs sudo):

- `apt` → `sudo apt install firejail`
- `pacman` → `sudo pacman -S firejail`
- `dnf` → `sudo dnf install firejail`

Never run the sudo command without the user confirming first.

## Step 4: Detect candidate directories

Ask the user which project directory they primarily work in if it isn't
already obvious from context. Then build a candidate list yourself:

1. Always include `$HOME/.claude`, `$HOME/.claude.json`,
   `$HOME/.claude.json.backup`, and `$HOME/.gitconfig` unconditionally —
   Claude Code's own config lives directly under `$HOME` in the `.claude.json`
   files (not under `$HOME/.claude/`), and git commits need `.gitconfig`
   (user name/email); without these, they're invisible once sandboxed.
2. Check which of these toolchain dirs actually exist on disk (`ls -d`
   each): `~/.npm`, `~/.m2`, `~/.cargo`, `~/.rustup`, `~/go`,
   `~/.cache/pip`, `~/.local/share/pipx`, `~/.cache/uv`, `~/.gradle`.
   Don't limit yourself to this list — if you notice other toolchain
   state dirs on this system (e.g. `~/.bundle`, `~/.dotnet`, `~/.sbt`),
   include them too.
3. Check which of these VCS/CLI auth config dirs actually exist on disk
   (`ls -d` each): `~/.config/gh` (GitHub CLI), `~/.config/glab-cli`
   (GitLab CLI), `~/.config/git` (alternate git config location), and the
   `~/.git-credentials` file. Missing these is what makes `gh`/`glab`
   report "not logged in" or git report missing credentials once
   sandboxed, even though `~/.gitconfig` (already in item 1) is present.
4. Check the project directory for manifest files and note which
   ecosystems are in play, even if the matching dir above doesn't exist
   yet (it will be created on first install): `package.json` → npm,
   `pom.xml` → maven, `build.gradle*` → gradle, `Cargo.toml` → cargo,
   `go.mod` → go, `requirements.txt`/`pyproject.toml` → pip.

For each candidate, note why it's a candidate (found on disk, matches a
project manifest, or both).

Present the full candidate list to the user with the `AskUserQuestion`
tool (multiSelect) so each directory is explicitly approved or rejected
before anything is written to disk. Do not skip this confirmation, and
do not add any directory the user didn't approve.

## Step 5: Generate the profile and allowlist doc

If `$HOME/.config/firejail/claude.profile` already exists, show its
current contents to the user and get confirmation before overwriting —
re-running this skill must never silently clobber a hand-edited profile.

Read `templates/claude.profile.template`. **Do not alter the hardening
lines** (`noroot`, `nonewprivs`, `nogroups`, `caps.drop all`, `seccomp`,
`seccomp.block-secondary`, `protocol unix,inet,inet6`, `private-tmp`,
`private-dev`, `private-etc ...`, `no3d`, `notv`, `nou2f`) — copy them
verbatim. Replace the
`{{WHITELIST_ENTRIES}}` line with one `whitelist <dir>` line per
user-approved directory from Step 4 (always includes `$HOME/.claude`,
`$HOME/.claude.json`, `$HOME/.claude.json.backup`, and `$HOME/.gitconfig`).
Write the result to `$HOME/.config/firejail/claude.profile`.

Read `templates/sandbox-allowed-dirs.md.template` and replace the
`{{ALLOWLIST_TABLE}}` line with one `` - `<dir>` `` line per approved
directory. Write the result to `$HOME/.claude/sandbox-allowed-dirs.md`.

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
`@sandbox-awareness.md`. If it does, skip this step — don't duplicate the
import.

Otherwise:

1. If `$HOME/.claude/sandbox-awareness.md` already exists, show its
   current contents to the user and get confirmation before overwriting —
   same rule as the firejail profile in Step 5. Then copy the contents of
   `templates/claude-md-snippet.md` verbatim to
   `$HOME/.claude/sandbox-awareness.md`.
2. Append the line `@sandbox-awareness.md` to `$HOME/.claude/CLAUDE.md`
   (creating the file first if it doesn't exist) — an import, not the
   full block, matching how other tools (e.g. `@RTK.md`) wire themselves
   into global CLAUDE.md.

## Done

Summarize for the user: which directories are now whitelisted, where the
profile lives (`~/.config/firejail/claude.profile`), that the alias/
function is active in new shells, and that adding another directory
later means either re-running this skill or hand-editing the profile
(`whitelist <path>` line) themselves — Claude cannot do this from inside
the sandbox by design.
