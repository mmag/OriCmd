#!/bin/zsh
# Demo folders for the README screenshots (scripts/screenshots.sh):
# a project, its backup copy and a Downloads folder.
set -e
cd "$(dirname $0)/.."
D=${1:-/tmp/OriCmd}
rm -rf $D
P=$D/Projects/OriCmd
mkdir -p $P/{Sources,Resources,Tests,docs,scripts} $D/Downloads $D/Backup
bytes() { head -c $2 /dev/urandom > $1 }
at() { touch -t $1 ${@:2} }

cat > $P/README.md <<'TEXT'
# OriCmd
A two-panel file manager for macOS in the spirit of Total Commander.
TEXT
cp LICENSE $P/LICENSE
cat > $P/Package.swift <<'TEXT'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "OriCmd")
TEXT
printf 'build:\n\txcodebuild build\n' > $P/Makefile
printf '#!/bin/sh\nxcodebuild -scheme OriCmd build\n' > $P/build.sh
cat > $P/notes.txt <<'TEXT'
Release checklist
1. Update the version number
2. Build the disk image
3. Run the regression tests
4. Write the release notes
5. Publish on GitHub
6. Tell everyone
TEXT
printf '## 0.2\n- Copy dialog like in Total Commander\n- Settings with panes\n' > $P/CHANGELOG.md
sips -s format png OriCmd/Assets.xcassets/AppIcon.appiconset/icon_256x256.png --out $P/icon.png >/dev/null
bytes $P/release.zip 2400000
bytes $P/OriCmd-0.2.dmg 3600000
for f in App Panel Transfer Settings; do printf 'import AppKit\n// %s\n' $f > $P/Sources/$f.swift; done
for f in AppIcon Localizable; do bytes $P/Resources/$f.bin 20000; done
printf 'import XCTest\n' > $P/Tests/TransferTests.swift
printf '# Guide\n' > $P/docs/guide.md
printf '#!/bin/sh\n' > $P/scripts/release.sh
find $P -exec touch -t 202609150930 {} +
at 202609201415 $P/release.zip $P/OriCmd-0.2.dmg; at 202609271130 $P/notes.txt $P/README.md
at 202609101200 $P/*(/)

# The backup: older, with a file missing and another changed.
cp -Rp $P $D/Backup/OriCmd
rm $D/Backup/OriCmd/CHANGELOG.md $D/Backup/OriCmd/Sources/Settings.swift
cat > $D/Backup/OriCmd/notes.txt <<'TEXT'
Release checklist
1. Update the version
2. Build the disk image
3. Run the tests
4. Publish on GitHub
TEXT
at 202609011000 $D/Backup/OriCmd/notes.txt $D/Backup/OriCmd/README.md
printf 'draft\n' > $D/Backup/OriCmd/todo.txt
at 202609051200 $D/Backup/OriCmd/todo.txt

# Downloads: pictures, video, music, archives, documents.
for n in 2041 2042 2043 2044 2045 2046; do
  sips -s format jpeg -z $((200 + n % 7 * 20)) $((300 + n % 5 * 30)) \
    OriCmd/Assets.xcassets/AppIcon.appiconset/icon_512x512.png --out $D/Downloads/IMG_$n.jpg >/dev/null
done
bytes $D/Downloads/holiday.mov 1800000
bytes $D/Downloads/song.mp3 420000
bytes $D/Downloads/photos.zip 950000
bytes $D/Downloads/installer.dmg 1300000
bytes $D/Downloads/report.pdf 180000
printf 'name,amount\ncoffee,3\n' > $D/Downloads/expenses.csv
at 202609251840 $D/Downloads/*
echo "Demo folders in $D"
