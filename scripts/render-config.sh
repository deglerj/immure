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
