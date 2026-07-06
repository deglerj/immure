## Sandbox awareness (immure / firejail)

FIRST STEP, before diagnosing ANY of these symptoms: run `echo
$CLAUDE_SANDBOXED`. If it prints `firejail`, you are sandboxed — a fixed
filesystem allowlist you cannot change from inside it. Do this check before
theorizing about the cause, not after.

Symptoms that mean "check sandbox first", not "tool is broken":
- Any file read/write/permission error.
- `git`/`gh`/similar CLI reporting not logged in, not authenticated, no
  credentials found, or config missing — this is usually the tool unable to
  reach its config/credential files (e.g. `~/.gitconfig`, `~/.config/gh`),
  not an actual logged-out state.
- Any tool behaving as if a dotfile/config it normally relies on doesn't
  exist.

If `$CLAUDE_SANDBOXED=firejail` and one of these hits, read
`~/.claude/sandbox-allowed-dirs.md` for the current allowlist before
retrying anything or telling the user the tool needs re-auth. If the needed
path isn't whitelisted, ask the user to add it — don't work around it
yourself (no re-auth, no copying credentials elsewhere, no disabling the
check).
