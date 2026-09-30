#!/bin/zsh
# Puts markdown-it (Markdown shown as a page), js-beautify (the Lister's formatting of
# JavaScript, CSS and HTML) and prettier with its TypeScript parser (formatting of
# TypeScript) into Highlighter/, the Lister's locked service. The packages come from
# npm and are checked against the checksums the registry publishes; their browser
# bundles have everything they need.
# Usage: scripts/update-jslibs.sh <markdown-it version> <js-beautify version> <prettier version>
set -euo pipefail
cd "$(dirname "$0")/.."

MARKDOWN_IT=${1:?usage: scripts/update-jslibs.sh <markdown-it version> <js-beautify version> <prettier version>}
JS_BEAUTIFY=${2:?usage: scripts/update-jslibs.sh <markdown-it version> <js-beautify version> <prettier version>}
PRETTIER=${3:?usage: scripts/update-jslibs.sh <markdown-it version> <js-beautify version> <prettier version>}
WORK=build/jslibs
rm -rf $WORK
mkdir -p $WORK

# fetch <package> <version>: the package unpacked into $WORK/<package>.
fetch() {
  local package=$1 version=$2
  curl -sfL -o $WORK/$package.tgz "https://registry.npmjs.org/$package/-/$package-$version.tgz"
  local expected=$(curl -sf "https://registry.npmjs.org/$package/$version" \
    | python3 -c 'import json, sys; print(json.load(sys.stdin)["dist"]["integrity"])')
  local actual="sha512-$(openssl dgst -sha512 -binary $WORK/$package.tgz | base64)"
  [ "$expected" = "$actual" ] || { echo "$package: checksum mismatch: $actual, npm says $expected"; exit 1; }
  mkdir -p $WORK/$package
  tar -xzf $WORK/$package.tgz -C $WORK/$package
}

fetch markdown-it $MARKDOWN_IT
cp $WORK/markdown-it/package/dist/browser/markdown-it.umd.min.js Highlighter/markdown-it.min.js
cp $WORK/markdown-it/package/LICENSE Highlighter/markdown-it-LICENSE.txt

fetch js-beautify $JS_BEAUTIFY
cp $WORK/js-beautify/package/js/lib/beautifier.min.js Highlighter/beautifier.min.js
cp $WORK/js-beautify/package/LICENSE Highlighter/js-beautify-LICENSE.txt

# The core, the printer for JavaScript-like trees, the TypeScript parser.
fetch prettier $PRETTIER
{
  cat $WORK/prettier/package/standalone.js
  printf '\n'
  cat $WORK/prettier/package/plugins/estree.js
  printf '\n'
  cat $WORK/prettier/package/plugins/typescript.js
} > Highlighter/prettier.min.js
cp $WORK/prettier/package/LICENSE Highlighter/prettier-LICENSE.txt
cp $WORK/prettier/package/THIRD-PARTY-NOTICES.md Highlighter/prettier-THIRD-PARTY-NOTICES.md

echo "markdown-it $MARKDOWN_IT, js-beautify $JS_BEAUTIFY, prettier $PRETTIER → Highlighter/"
