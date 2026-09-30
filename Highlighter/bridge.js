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

// Every language name and alias highlight.js knows, one a line.
function oricmdLanguageNames() {
  const names = [];
  for (const name of hljs.listLanguages()) {
    names.push(name, ...(hljs.getLanguage(name).aliases || []));
  }
  return names.join("\n");
}

// Markdown as HTML (markdown-it: CommonMark, tables, strikethrough, bare addresses as
// links). HTML written in the text is kept: OriCmd shows the page with JavaScript off
// and nothing from the network. Code blocks are colored by highlight.js (classes
// hljs-*), YAML front matter shows as a code block, task list boxes as ☐ and ☑.
let oricmdMarkdownIt = null;
function oricmdMarkdown(text) {
  if (!oricmdMarkdownIt) {
    oricmdMarkdownIt = markdownit({
      html: true, linkify: true,
      highlight: (code, language) => {
        if (!language || !hljs.getLanguage(language)) return "";
        try { return hljs.highlight(code, { language: language, ignoreIllegals: true }).value; } catch (e) { return ""; }
      },
    });
  }
  const frontMatter = /^---\r?\n([\s\S]*?)\r?\n---\r?\n/.exec(text);
  if (frontMatter) text = "```yaml\n" + frontMatter[1].replace(/```/g, "` ` `") + "\n```\n" + text.slice(frontMatter[0].length);
  return oricmdMarkdownIt.render(text)
    .replace(/<li>(<p>)?\[([ xX])\] /g, (match, paragraph, mark) =>
      `<li class="task">${paragraph || ""}${mark === " " ? "☐" : "☑"} `);
}

// `text` laid out for reading: "js", "css", "html" by js-beautify (tokens kept as they
// are, broken code too); "ts", "tsx" by prettier (js-beautify does not know
// TypeScript), whose answer is a promise: it is settled once this call has returned
// (JavaScriptCore runs promise reactions then), and oricmdPendingResult() gives it.
let oricmdPending = null;
function oricmdFormat(text, kind) {
  const options = { indent_size: kind === "html" ? 2 : 4, preserve_newlines: true, max_preserve_newlines: 2,
                    wrap_line_length: 0, end_with_newline: true };
  switch (kind) {
    case "js": return beautifier.js(text, options);
    case "css": return beautifier.css(text, options);
    case "html": return beautifier.html(text, options);
    case "ts": case "tsx": {
      const pending = oricmdPending = { value: null };
      prettier.format(text, { parser: "typescript", filepath: "file." + kind, plugins: Object.values(prettierPlugins),
                              tabWidth: 4, printWidth: 110 })
        .then(value => { pending.value = value; }, () => {});
      return null;
    }
    default: return null;
  }
}

function oricmdPendingResult() {
  const pending = oricmdPending;
  oricmdPending = null;
  return pending ? pending.value : null;
}
