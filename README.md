# immure

A Claude Code plugin that sandboxes Claude Code itself behind
[firejail](https://firejail.wordpress.com/), restricting filesystem access to
a directory allowlist you approve — and that Claude cannot read or modify
once sandboxed.

## What it does

- **Whitelist mode**: only approved directories are visible inside the
  sandbox. Everything else is hidden, not just read-only.
- **Config is unreachable from inside**: `~/.config/firejail/` (where the
  firejail profile lives) is never added to the whitelist, so a sandboxed
  Claude can't read or edit its own restrictions.
- **Hardened profile**: drops Linux capabilities and supplementary groups,
  blocks privilege escalation, applies seccomp filtering, restricts socket
  families, and gives Claude a private `/tmp` and `/dev`.
- **What it's not**: not a VM (shares the host kernel — a kernel exploit
  still escapes it), doesn't restrict outbound TCP/IP (npm/pip/cargo/git/the
  Anthropic API all need it), not a substitute for reviewing what Claude
  Code actually does.

## Requirements

- Linux with `firejail` installed (the skill offers to install it via `apt`
  or `pacman`; `dnf`/Fedora is best-effort).

## Install

```
/plugin marketplace add deglerj/immure
/plugin install immure
```

Then ask Claude to sandbox itself, e.g. "sandbox Claude Code with immure" —
the skill walks through OS detection, directory allowlist approval, profile
generation, and shell alias setup interactively.

To add a directory to an already-sandboxed setup later, just ask again (or
hand-edit the `whitelist <path>` line in `~/.config/firejail/claude.profile`
— Claude can't do this from inside the sandbox by design).

## More detail

See `skills/immure/SKILL.md` for the full step-by-step flow, and
[`docs/superpowers/specs/2026-07-05-firejail-sandbox-skill-design.md`](docs/superpowers/specs/2026-07-05-firejail-sandbox-skill-design.md)
for the design rationale.

## License

MIT — see [LICENSE](LICENSE).
