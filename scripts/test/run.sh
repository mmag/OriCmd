#!/bin/zsh
# Usage: scripts/test/run.sh <name> "<keys>"  — plays keys on test dirs, writes build/shots/<name>.png
# The interface is English here, whatever language is chosen in OriCmd (UI_LANGUAGE=ru for Russian).
# The app is started in the background (open -g) and never activates itself: the focus stays where it is.
setopt nullglob
cd "$(dirname $0)/../.."
mkdir -p build/shots
name=$1; keys=$2
rm -f build/shots/$name.png build/shots/$name-sheet* build/shots/$name-win* build/shots/$name-terminal.*
# RIGHT_PANEL: another folder for the right panel (e.g. a path through a symlink).
# ORICMD_DDJVU: the ddjvu that draws DjVu pages (none unless given, whatever is installed).
# ORICMD_UNAR_DIR: where lsar and unar are (for solid RAR 4; none unless given).
# ORICMD_VETO: names copies cannot create, as a server's "veto files" (/.DS_Store/Thumbs.db/).
open -g -W -n --env ORICMD_LEFT=$PWD/build/testdata/left --env ORICMD_RIGHT=${RIGHT_PANEL:-$PWD/build/testdata/right} \
  --env ORICMD_SSH_CONFIG=$PWD/build/sshtest/ssh_config --env ORICMD_DDJVU=${ORICMD_DDJVU:-} \
  --env ORICMD_UNAR_DIR=${ORICMD_UNAR_DIR:-} --env ORICMD_VETO=${ORICMD_VETO:-} \
  --env "ORICMD_KEYS=$keys" --env ORICMD_SNAPSHOT=$PWD/build/shots/$name.png --env ORICMD_QUIT=1 \
  build/DerivedData/Build/Products/Debug/OriCmd.app --args -AppleLanguages "(${UI_LANGUAGE:-en})"
for f in build/shots/$name*.png; do
  [ -f $f ] && sips -Z 1100 $f --out $f >/dev/null && echo "saved $f"
done; defaults delete ru.themmag.OriCmd.tests 2>/dev/null; exit 0
