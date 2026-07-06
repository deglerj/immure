## Sandbox awareness (immure / firejail)

You may be running inside a firejail sandbox (`$CLAUDE_SANDBOXED=firejail`
is set when so). Filesystem access is a fixed allowlist you cannot change
from inside the sandbox. If you hit a permission/write error that looks
like a sandbox restriction (not a normal permission error), read
`~/.claude/sandbox-allowed-dirs.md` for the current allowlist before
retrying anything, and ask the user to add a directory — don't try to
work around it yourself.
