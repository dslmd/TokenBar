#!/usr/bin/env bash
# Renders the UI with demo data to PNG files (light and dark) in build/snapshots/.
# No accounts, Keychain, network or screen permissions are involved.
#
# Usage: scripts/snapshot.sh [extra snapshot options]
#   --snapshot-only <text>            only shots whose name contains <text>, e.g. popover
#   --snapshot-scale <2|1|3|native>   pixels per point (default 2)
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script only runs on macOS." >&2
  exit 1
fi

cd "$(dirname "$0")/.."
OUT="build/snapshots"

swift build --product TokenBar
BIN="$(swift build --show-bin-path)/TokenBar"

rm -rf "$OUT"
mkdir -p "$OUT"
STATUS=0
"$BIN" --snapshot "$OUT" "$@" || STATUS=$?

echo
echo "Files in $OUT:"
ls -1 "$OUT"
if [[ "$STATUS" -ne 0 ]]; then
  echo "Snapshot mode reported problems (exit $STATUS), see the lines marked FAILED or BLANK above." >&2
fi
exit "$STATUS"
