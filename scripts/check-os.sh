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
