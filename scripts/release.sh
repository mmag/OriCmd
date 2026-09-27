#!/bin/zsh
# Publishes OriCmd <version> on GitHub Releases, where the app looks for updates:
# sets the version, builds the DMG, commits, tags, pushes and uploads the DMG,
# then updates the Homebrew cask in mmag/homebrew-tap.
# Usage: scripts/release.sh 0.2 [notes.md]   (without notes GitHub lists the commits)
# A letter suffix marks a pre-release version: 0.2b, 0.3rc1.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${1:?usage: scripts/release.sh <version> [notes.md]}
NOTES=${2:-}
[[ $VERSION =~ '^[0-9]+(\.[0-9]+)*([a-z]+[0-9]*)?$' ]] || { echo "Version must look like 0.2, 1.0.1 or 0.2b"; exit 1; }
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

# Homebrew: brew install --cask mmag/tap/oricmd
TAP=build/homebrew-tap
rm -rf $TAP
git clone -q https://github.com/mmag/homebrew-tap.git $TAP
SHA=$(shasum -a 256 $DMG | cut -d ' ' -f 1)
cat > $TAP/Casks/oricmd.rb <<CASK
cask "oricmd" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/mmag/OriCmd/releases/download/v#{version}/OriCmd-#{version}.dmg"
  name "OriCmd"
  desc "Two-panel file manager with a familiar look and keyboard control"
  homepage "https://github.com/mmag/OriCmd"

  auto_updates true
  depends_on macos: :sonoma

  app "OriCmd.app"

  zap trash: [
    "~/Library/Caches/ru.themmag.OriCmd",
    "~/Library/Preferences/ru.themmag.OriCmd.plist",
    "~/Library/Saved Application State/ru.themmag.OriCmd.savedState",
  ]
end
CASK
git -C $TAP add Casks/oricmd.rb
git -C $TAP commit -q -m "oricmd $VERSION"
git -C $TAP push -q origin HEAD
echo "Homebrew cask oricmd $VERSION published"
