#!/bin/zsh
# Usage: scripts/test/run.sh <name> "<keys>"  — plays keys on test dirs, writes build/shots/<name>.png
setopt nullglob
cd "$(dirname $0)/../.."
mkdir -p build/shots
name=$1; keys=$2
rm -f build/shots/$name.png build/shots/$name-sheet*.png
open -W -n --env ORICMD_LEFT=$PWD/build/testdata/left --env ORICMD_RIGHT=$PWD/build/testdata/right \
  --env ORICMD_SSH_CONFIG=$PWD/build/sshtest/ssh_config \
  --env "ORICMD_KEYS=$keys" --env ORICMD_SNAPSHOT=$PWD/build/shots/$name.png --env ORICMD_QUIT=1 \
  build/DerivedData/Build/Products/Debug/OriCmd.app
for f in build/shots/$name*.png; do
  [ -f $f ] && sips -Z 1100 $f --out $f >/dev/null && echo "saved $f"
done; defaults delete ru.themmag.OriCmd.tests 2>/dev/null; exit 0
