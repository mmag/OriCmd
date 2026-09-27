#!/bin/zsh
# Publishes OriCmd <version> on GitHub Releases, where the app looks for updates:
# sets the version, builds the DMG, commits, tags, pushes and uploads the DMG.
# Usage: scripts/release.sh 0.2 [notes.md]   (without notes GitHub lists the commits)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${1:?usage: scripts/release.sh <version> [notes.md]}
NOTES=${2:-}
[[ $VERSION =~ '^[0-9]+(\.[0-9]+)*$' ]] || { echo "Version must look like 0.2 or 1.0.1"; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "Commit or stash the changes first"; exit 1; }
[ "$(git branch --show-current)" = main ] || { echo "Releases are made from main"; exit 1; }
! git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null || { echo "Tag v$VERSION already exists"; exit 1; }
gh auth status >/dev/null

PROJECT=OriCmd.xcodeproj/project.pbxproj
BUILD=$(( $(awk '/CURRENT_PROJECT_VERSION/ { gsub(";", "", $3); print $3; exit }' $PROJECT) + 1 ))
sed -i '' -e "s/MARKETING_VERSION = [0-9.]*;/MARKETING_VERSION = $VERSION;/" \
  -e "s/CURRENT_PROJECT_VERSION = [0-9]*;/CURRENT_PROJECT_VERSION = $BUILD;/" $PROJECT

scripts/make-dmg.sh
DMG=build/OriCmd-$VERSION.dmg
[ -f $DMG ] || { echo "$DMG was not built"; exit 1; }

git commit -q -am "Release $VERSION"
git tag "v$VERSION"
git push origin main "v$VERSION"

if [ -n "$NOTES" ]; then
  gh release create "v$VERSION" $DMG --title "OriCmd $VERSION" --notes-file "$NOTES"
else
  gh release create "v$VERSION" $DMG --title "OriCmd $VERSION" --generate-notes
fi
