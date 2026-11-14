#!/usr/bin/env bash
# Builds a debug build, stops any running TokenBar and starts the fresh one.
#
# Usage: scripts/dev-run.sh [--demo [scenario]]
#   --demo [scenario]   run the real menu bar app on demo data instead of your accounts: nothing is
#                       read from disk, the Keychain or the network, and nothing is saved.
#                       Scenarios: rich (default), signingIn, sparse, empty, scanning, allOff, loading
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script only runs on macOS." >&2
  exit 1
fi

cd "$(dirname "$0")/.."

swift build --product TokenBar
BIN="$(swift build --show-bin-path)/TokenBar"

# Stops an installed copy as well as an earlier development build.
if pkill -x TokenBar 2>/dev/null; then
  sleep 1
fi

LOG="build/dev-run.log"
mkdir -p build
nohup "$BIN" "$@" >"$LOG" 2>&1 &
echo "Started $BIN $* (pid $!), output in $LOG"
echo "Stop it with: pkill -x TokenBar"
