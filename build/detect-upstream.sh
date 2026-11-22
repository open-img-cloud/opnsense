#!/usr/bin/env bash
# Prints the current OPNsense release with its hotfix level (e.g. 26.7.9_3):
# the version of the `opnsense` core package in the package repository of
# the newest series whose image signing key is pinned in keys/. Runs in the
# upstream-watch reusable workflow; a new version opens a release PR.
#
# A newer series (27.1 in January) is only reported as a notice: its key
# must be reviewed and added to keys/ first (from the release README and an
# independent source such as the forum announcement).
set -euo pipefail
UA='openimages.cloud-watch'
HERE=$(cd "$(dirname "$0")/.." && pwd)

series=$(curl -fsSL -A "$UA" https://pkg.opnsense.org/releases/ \
  | grep -oE 'href="[0-9]{2}\.[17]/' | grep -oE '[0-9]{2}\.[17]' | sort -uV)
pinned=""
for s in $series; do
  [[ -f "$HERE/keys/OPNsense-$s.pub" ]] && pinned=$s
done
newest=$(printf '%s\n' $series | tail -1)
if [[ -z "$pinned" ]]; then
  echo "::error::no OPNsense series has a pinned key in keys/" >&2
  exit 1
fi
if [[ "$newest" != "$pinned" ]]; then
  echo "::notice::OPNsense $newest is out: add keys/OPNsense-$newest.pub to follow it (now on $pinned)" >&2
fi

for abi in 15 14 16; do
  listing=$(curl -fsSL -A "$UA" "https://pkg.opnsense.org/FreeBSD:$abi:amd64/$pinned/latest/All/" 2>/dev/null) || continue
  v=$(printf '%s\n' "$listing" | grep -oE "opnsense-${pinned//./\\.}(\.[0-9]+)?(_[0-9]+)?\.pkg" \
      | sed -E 's/^opnsense-//; s/\.pkg$//' | sort -uV | tail -1)
  if [[ -n "$v" ]]; then
    printf '%s\n' "$v"
    exit 0
  fi
done
echo "::error::no opnsense core package found for series $pinned" >&2
exit 1
