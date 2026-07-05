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
