#!/usr/bin/env bash
#
# End-to-end Svod macOS release: build (Xcode, Release) → Developer-ID export →
# DMG → notarize → staple → Sparkle EdDSA sign → appcast bump. One command instead
# of a runbook. Same model as the Lattice app's Scripts/release.sh.
#
# Usage:
#   Scripts/release.sh <version> [build]
#       <version>  marketing version, e.g. 0.2.0 (CFBundleShortVersionString)
#       [build]    integer build number; default = current CURRENT_PROJECT_VERSION
#
# Flags (env):
#   NOTARY_PROFILE=lattice-notary   notarytool keychain profile (per-account, reused
#                                   across apps under the same team — store once).
#   TEAM=UQK5BS5U9A                 Developer ID team.
#   SKIP_NOTARIZE=1                 build + sign + DMG only (local dry run, NOT shippable).
#   PUBLISH=1                       after a green build: prepend+commit the appcast item,
#                                   push, and `gh release` the DMG. WITHOUT this the
#                                   script stops after artifacts and PRINTS the publish
#                                   commands — releasing is never a side effect of a build.
#
# Prereqs: Xcode, xcrun (notarytool/stapler), Sparkle's sign_update (fetched by SPM),
# and — for PUBLISH — gh. Certificates + the notary profile are yours (keychain); this
# script never handles secrets directly.
set -euo pipefail

VERSION="${1:-}"
[ -n "$VERSION" ] || { echo "ERROR: version required, e.g. Scripts/release.sh 0.2.0" >&2; exit 1; }

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"
TEAM="${TEAM:-UQK5BS5U9A}"
NOTARY_PROFILE="${NOTARY_PROFILE:-lattice-notary}"
APPCAST="$REPO/appcast.xml"
ARCHIVE="$REPO/build/release/Svod.xcarchive"
EXPORT="$REPO/build/release/export"
APP="$EXPORT/Svod.app"
DMG="$REPO/build/release/Svod-macOS-$VERSION.dmg"
TAG="v$VERSION"

# build number: bump the project's current value unless given.
CUR_BUILD="$(/usr/bin/sed -n 's/.*CURRENT_PROJECT_VERSION = \([0-9]*\);.*/\1/p' Svod.xcodeproj/project.pbxproj | head -1)"
BUILD="${2:-${CUR_BUILD:-1}}"

echo "==> Svod release $VERSION (build $BUILD)"
if grep -q "<sparkle:shortVersionString>$VERSION<" "$APPCAST" 2>/dev/null; then
  echo "WARNING: appcast already has an item for $VERSION — a new item will be prepended." >&2
fi

# 1. Resolve SPM (ensures Sparkle's sign_update is present) + archive (Release).
echo "==> resolve packages"
xcodebuild -project Svod.xcodeproj -scheme Svod -resolvePackageDependencies >/dev/null
echo "==> archive (Release)"
rm -rf "$ARCHIVE" "$EXPORT"
xcodebuild -project Svod.xcodeproj -scheme Svod -configuration Release \
  -archivePath "$ARCHIVE" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  DEVELOPMENT_TEAM="$TEAM" \
  -destination 'generic/platform=macOS' archive

# 2. Export a Developer-ID-signed .app (frameworks incl. Sparkle signed inside-out).
echo "==> exportArchive (developer-id)"
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT" -exportOptionsPlist Scripts/ExportOptions.plist
[ -d "$APP" ] || { echo "ERROR: export produced no Svod.app" >&2; exit 1; }
codesign --verify --deep --strict --verbose=1 "$APP"

# 3. DMG.
echo "==> make-dmg"
./Scripts/make-dmg.sh "$APP" "$DMG"

# 4. Notarize + staple (unless skipped).
if [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
  echo "==> SKIP_NOTARIZE=1 — leaving $DMG un-notarized (NOT shippable)"
else
  IDENT="$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 'Developer ID Application' | sed -E 's/.*"(.*)".*/\1/')"
  [ -n "$IDENT" ] || { echo "ERROR: no Developer ID Application identity in keychain." >&2; exit 1; }
  echo "==> codesign DMG ($IDENT)"
  codesign --force --sign "$IDENT" --timestamp "$DMG"
  echo "==> notarytool submit (profile: $NOTARY_PROFILE) — waiting…"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  echo "==> stapler staple"
  xcrun stapler staple "$DMG"
  spctl -a -t open --context context:primary-signature "$DMG"
fi

# 5. Sparkle EdDSA signature + length for the appcast enclosure.
echo "==> sign_update (Sparkle EdDSA)"
SIGN_UPDATE="$(find "$HOME/Library/Developer/Xcode/DerivedData" -ipath '*Svod*' -name sign_update -type f 2>/dev/null | head -1)"
[ -n "$SIGN_UPDATE" ] || { echo "ERROR: sign_update not found — run a build once to fetch Sparkle." >&2; exit 1; }
SIG_LINE="$("$SIGN_UPDATE" "$DMG")"   # → sparkle:edSignature="…"[ length="…"]
LENGTH="$(/usr/bin/stat -f%z "$DMG")"
case "$SIG_LINE" in
  *length=*) ENCLOSURE_ATTRS="$SIG_LINE" ;;
  *)         ENCLOSURE_ATTRS="$SIG_LINE length=\"$LENGTH\"" ;;
esac
echo "    $ENCLOSURE_ATTRS"

# 6. Prepend a fresh appcast item (newest-first; Sparkle picks the latest).
echo "==> updating appcast.xml"
PUBDATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
ENCLOSURE_URL="https://github.com/FleetQ/svod-ui-macos/releases/download/$TAG/Svod-macOS-$VERSION.dmg"
ITEM=$(cat <<EOF
    <item>
      <title>Version $VERSION</title>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[<ul><li>See the GitHub release notes for $TAG.</li></ul>]]></description>
      <pubDate>$PUBDATE</pubDate>
      <enclosure url="$ENCLOSURE_URL" $ENCLOSURE_ATTRS type="application/octet-stream" />
    </item>
EOF
)
ITEM="$ITEM" awk '
  !done && /^[[:space:]]*<item>/ { print ENVIRON["ITEM"]; done=1 }
  !done && /<\/channel>/         { print ENVIRON["ITEM"]; done=1 }
  { print }
' "$APPCAST" > "$APPCAST.tmp" && mv "$APPCAST.tmp" "$APPCAST"

echo ""
echo "==> artifacts ready:"
echo "    DMG:     $DMG ($(/usr/bin/du -h "$DMG" | cut -f1))"
echo "    appcast: $APPCAST (item for $VERSION prepended)"

# 7. Publish — ONLY with PUBLISH=1. Otherwise print the commands and stop.
if [ "${PUBLISH:-0}" = "1" ]; then
  echo "==> PUBLISH=1 — pushing the release commit, then creating the GitHub release"
  # ORDER MATTERS. `gh release create` tags whatever the remote HEAD is, so creating the
  # release BEFORE pushing the appcast commit tags the commit *before* the release — the
  # tag drift this project has hit repeatedly. Commit and push first; the tag then lands on
  # the release commit.
  git add appcast.xml Svod.xcodeproj/project.pbxproj
  # "Nothing staged" is legitimate on a re-run of a version already committed; ANY OTHER commit
  # failure is not, and must stop the release. `git commit || true` would swallow a hook rejection
  # and push+tag anyway — re-creating the very tag drift this ordering exists to prevent.
  if git diff --cached --quiet; then
    echo "    (nothing new to commit — assuming a re-run)"
  elif ! git commit -m "release(macos): v$VERSION (build $BUILD)"; then
    echo "ERROR: the release commit failed; not pushing and not tagging." >&2
    exit 1
  fi
  git push
  # Retry: GitHub 5xx during a publish once left the appcast uncommitted and the release
  # missing, because `set -e` killed the script on the failed create. The commit is now
  # already safe above, and a transient failure here is retried rather than fatal.
  published=0
  for attempt in 1 2 3 4 5; do
    if gh release create "$TAG" "$DMG" --title "Svod for macOS $VERSION" \
         --notes "Svod for macOS $VERSION." 2>/dev/null; then
      published=1; break
    fi
    # The tag may already exist (a retry, or a re-run) — then just upload the asset.
    if gh release upload "$TAG" "$DMG" --clobber 2>/dev/null; then
      published=1; break
    fi
    if [ "$attempt" -lt 5 ]; then
      echo "    publish attempt $attempt failed; retrying in 20s"
      sleep 20
    fi
  done
  # A release can come back as a DRAFT, and a draft creates NO TAG — so `git ls-remote` shows
  # nothing while `gh release view` happily shows the asset. Observed on v0.2.19 during a GitHub
  # incident: two `create` attempts failed, the third produced a draft, and the tag was simply
  # absent until it was published by hand. Sparkle would have served an enclosure URL pointing at a
  # release nobody could download.
  if [ "$published" = "1" ]; then
    if [ "$(gh release view "$TAG" --json isDraft --jq .isDraft 2>/dev/null)" = "true" ]; then
      echo "==> release came back as a draft — publishing it so the tag is created"
      gh release edit "$TAG" --draft=false >/dev/null || {
        echo "ERROR: $TAG is a DRAFT and could not be published. No tag exists yet." >&2
        echo "       Fix with: gh release edit $TAG --draft=false" >&2
        exit 1
      }
    fi
    # The tag is what the appcast enclosure URL depends on; verify it actually exists.
    if ! git ls-remote --tags origin "refs/tags/$TAG" | grep -q "$TAG"; then
      echo "ERROR: $TAG is not on the remote — the appcast enclosure URL would 404." >&2
      exit 1
    fi
  fi
  if [ "$published" != "1" ]; then
    echo "ERROR: could not publish $TAG after 5 attempts. The appcast commit IS pushed;" >&2
    echo "       re-run: gh release create $TAG \"$DMG\" --title \"Svod for macOS $VERSION\"" >&2
    exit 1
  fi
  echo "==> published $TAG and pushed appcast."
else
  echo ""
  echo "==> build complete. To PUBLISH: re-run with PUBLISH=1, or manually (IN THIS ORDER —"
  echo "    the release tags the remote HEAD, so the commit must be pushed first):"
  echo "    git add appcast.xml Svod.xcodeproj/project.pbxproj"
  echo "    git commit -m \"release(macos): v$VERSION (build $BUILD)\" && git push"
  echo "    gh release create $TAG \"$DMG\" --title \"Svod for macOS $VERSION\""
fi
