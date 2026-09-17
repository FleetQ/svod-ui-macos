#!/usr/bin/env bash
#
# Run Scripts/release.sh inside the logged-in user's GUI (Aqua) session and wait for it.
#
#   Scripts/release-via-gui-session.sh <version> [build]      (PUBLISH=1 and other env pass through)
#
# Why: an agent's shell runs in a launchd Background session, where the login keychain is out of
# reach — codesign fails with errSecInternalComponent and notarytool cannot read its profile. A
# Terminal window opened with `open` runs in the Aqua session instead, where the Developer ID key,
# the `lattice-notary` profile and Sparkle's EdDSA key all work with nobody at the Mac, as long as
# the user stays logged in. The script runs under `zsh -li`: under bash in that same window
# notarytool reported "No Keychain password item found for profile: lattice-notary".
#
# Output goes to build/release/release-<version>.log; the exit code of release.sh is this
# script's exit code.
set -euo pipefail

VERSION="${1:-}"
[ -n "$VERSION" ] || { echo "usage: $0 <version> [build]" >&2; exit 2; }
BUILD="${2:-}"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG="$REPO/build/release/release-$VERSION.log"
STATUS="$REPO/build/release/release-$VERSION.status"
mkdir -p "$REPO/build/release"
rm -f "$LOG" "$STATUS"

launcher="$(mktemp "${TMPDIR:-/tmp}/svod-release.XXXXXX")"
mv "$launcher" "$launcher.command"
launcher="$launcher.command"
{
  echo '#!/bin/zsh -li'
  printf 'cd %q || exit 1\n' "$REPO"
  for var in PUBLISH SKIP_NOTARIZE NOTARY_PROFILE TEAM; do
    if [ -n "${!var:-}" ]; then printf 'export %s=%q\n' "$var" "${!var}"; fi
  done
  printf 'Scripts/release.sh %q %s > %q 2>&1\n' "$VERSION" "${BUILD:+$(printf '%q' "$BUILD")}" "$LOG"
  printf 'echo $? > %q\n' "$STATUS"
  printf 'rm -f %q\n' "$launcher"
} > "$launcher"
chmod 700 "$launcher"

open -a Terminal "$launcher"
echo "==> release.sh $VERSION running in the GUI session; log: $LOG"

# A release (archive + notarization) takes minutes; give up after an hour.
for _ in $(seq 1 720); do
  [ -s "$STATUS" ] && break
  sleep 5
done
[ -s "$STATUS" ] || { echo "ERROR: no result after 60 minutes; see $LOG" >&2; exit 1; }

code="$(cat "$STATUS")"
tail -n 25 "$LOG"
exit "$code"
