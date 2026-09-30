// Highlights `code` in the first of `languages` highlight.js knows. Returns the
// language used, the scopes met and a Uint32Array of (start, length, scope index)
// in UTF-16 units, outer ranges before the ones inside them. The token tree
// (_emitter.rootNode) is highlight.js's own: check it after updating highlight.js
// (scripts/update-highlightjs.sh; the regression suite highlights a Swift file).
function oricmdHighlight(code, languages) {
  const language = languages.find(name => hljs.getLanguage(name));
  if (!language) return null;
  const result = hljs.highlight(code, { language: language, ignoreIllegals: true });
  const scopes = [], indexes = new Map(), ranges = [];
  let position = 0;
  const walk = node => {
    for (const child of node.children) {
      if (typeof child === "string") { position += child.length; continue; }
      let slot = -1;
      if (child.scope) {
        let index = indexes.get(child.scope);
        if (index === undefined) { index = scopes.length; scopes.push(child.scope); indexes.set(child.scope, index); }
        slot = ranges.length;
        ranges.push(position, 0, index);
      }
      walk(child);
      if (slot >= 0) ranges[slot + 1] = position - ranges[slot];
    }
  };
  walk(result._emitter.rootNode);
  return { language: language, scopes: scopes, ranges: Uint32Array.from(ranges) };
}
