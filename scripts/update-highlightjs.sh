#!/bin/zsh
# Puts highlight.js <version> (all its languages) into Highlighter/ for the Lister's
# syntax highlighting service. The package comes from npm (@highlightjs/cdn-assets)
# and is checked against the checksum the registry publishes.
# Usage: scripts/update-highlightjs.sh 11.12.0
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${1:?usage: scripts/update-highlightjs.sh <version>}
WORK=build/highlightjs
rm -rf $WORK
mkdir -p $WORK

curl -sfL -o $WORK/package.tgz "https://registry.npmjs.org/@highlightjs/cdn-assets/-/cdn-assets-$VERSION.tgz"
EXPECTED=$(curl -sf "https://registry.npmjs.org/@highlightjs/cdn-assets/$VERSION" \
  | python3 -c 'import json, sys; print(json.load(sys.stdin)["dist"]["integrity"])')
ACTUAL="sha512-$(openssl dgst -sha512 -binary $WORK/package.tgz | base64)"
[ "$EXPECTED" = "$ACTUAL" ] || { echo "Checksum mismatch: $ACTUAL, npm says $EXPECTED"; exit 1; }
tar -xzf $WORK/package.tgz -C $WORK

# The core with the common languages, then every language (each registers itself).
{
  cat $WORK/package/highlight.min.js
  for language in $WORK/package/languages/*.min.js; do
    printf '\n'
    cat $language
  done
} > Highlighter/highlight.min.js
cp $WORK/package/LICENSE Highlighter/highlight.js-LICENSE.txt
echo "highlight.js $VERSION ($(ls $WORK/package/languages/*.min.js | wc -l | tr -d ' ') languages) → Highlighter/highlight.min.js"
