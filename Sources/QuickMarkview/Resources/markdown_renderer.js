(function () {
  "use strict";
  // markdown-it and Mermaid are bundled beside this file. Both are loaded from
  // the app bundle, so rendering never waits on a network request.
  const md = window.markdownit({html: false, linkify: true, typographer: true});
  const esc = md.utils.escapeHtml;
  mermaid.initialize({startOnLoad: false, securityLevel: "strict"});

  function sourceAttrs(token) {
    if (!token.map) return;
    token.attrSet("data-source-start", String(token.map[0] + 1));
    token.attrSet("data-source-end", String(Math.max(token.map[0] + 1, token.map[1])));
  }

  // markdown-it emits source maps on block tokens. Adding attributes to the
  // opening token preserves those maps through normal nested Markdown, tables,
  // links, and lists without a fragile HTML regex pass.
  md.renderer.rules.heading_open = (tokens, idx, options, env, self) => { sourceAttrs(tokens[idx]); return self.renderToken(tokens, idx, options); };
  md.renderer.rules.paragraph_open = (tokens, idx, options, env, self) => { sourceAttrs(tokens[idx]); return self.renderToken(tokens, idx, options); };
  md.renderer.rules.blockquote_open = (tokens, idx, options, env, self) => { sourceAttrs(tokens[idx]); return self.renderToken(tokens, idx, options); };
  md.renderer.rules.bullet_list_open = (tokens, idx, options, env, self) => { sourceAttrs(tokens[idx]); return self.renderToken(tokens, idx, options); };
  md.renderer.rules.ordered_list_open = (tokens, idx, options, env, self) => { sourceAttrs(tokens[idx]); return self.renderToken(tokens, idx, options); };
  md.renderer.rules.list_item_open = (tokens, idx, options, env, self) => { sourceAttrs(tokens[idx]); return self.renderToken(tokens, idx, options); };
  md.renderer.rules.table_open = (tokens, idx, options, env, self) => { sourceAttrs(tokens[idx]); return self.renderToken(tokens, idx, options); };
  md.renderer.rules.hr = (tokens, idx, options, env, self) => { sourceAttrs(tokens[idx]); return self.renderToken(tokens, idx, options); };
  md.renderer.rules.tr_open = (tokens, idx, options, env, self) => { sourceAttrs(tokens[idx]); return self.renderToken(tokens, idx, options); };
  md.renderer.rules.code_block = (tokens, idx) => {
    const token = tokens[idx], start = token.map ? token.map[0] + 1 : 1, end = token.map ? Math.max(start, token.map[1]) : start;
    return `<pre data-source-start="${start}" data-source-end="${end}"><code>${esc(token.content)}</code></pre>\n`;
  };
  md.renderer.rules.image = (tokens, idx, options, env, self) => {
    const token = tokens[idx], source = token.attrGet("src") || "";
    // Keep viewing offline: relative images in the document are allowed, but
    // remote images must never trigger an implicit WebKit network request.
    if (/^(https?:|\/\/)/i.test(source)) token.attrSet("src", "#");
    return self.renderToken(tokens, idx, options);
  };

  md.renderer.rules.fence = (tokens, idx) => {
    const token = tokens[idx], language = token.info.trim().split(/\s+/)[0].toLowerCase();
    const start = token.map ? token.map[0] + 1 : 1, end = token.map ? Math.max(start, token.map[1]) : start;
    if (language === "mermaid") {
      return `<div class="mermaid" data-source-start="${start}" data-source-end="${end}" data-mermaid-source="${encodeURIComponent(token.content)}"></div>`;
    }
    const klass = language ? ` class="language-${esc(language)}"` : "";
    return `<pre data-source-start="${start}" data-source-end="${end}"><code${klass}>${esc(token.content)}</code></pre>\n`;
  };

  function renderMermaid(container, version) {
    const source = decodeURIComponent(container.dataset.mermaidSource || "");
    return mermaid.render(`quickmarkview-${Math.random().toString(36).slice(2)}`, source).then(result => {
      if (version !== window.quickMarkview.renderVersion) return;
      container.innerHTML = result.svg;
      if (result.bindFunctions) result.bindFunctions(container);
      return result;
    }).catch(error => {
      if (version !== window.quickMarkview.renderVersion) return;
      container.innerHTML = `<pre class="mermaid-error">Mermaid could not render this diagram: ${esc(error && error.message ? error.message : "unknown error")}</pre>`;
    });
  }

  function nearest(node) {
    while (node && node.nodeType === 3) node = node.parentElement;
    return node && node.closest ? node.closest("[data-source-start]") : null;
  }

  const post = message => window.webkit.messageHandlers.quickMarkview.postMessage(message);

  function sendSelection() {
    const selection = window.getSelection();
    if (!selection || selection.isCollapsed || !selection.toString().trim()) {
      post({type: "selectionCleared", revision: window.quickMarkview.currentRevision});
      return;
    }
    const nodes = [nearest(selection.anchorNode), nearest(selection.focusNode)].filter(Boolean);
    if (!nodes.length) return;
    const starts = nodes.map(node => Number(node.dataset.sourceStart));
    const ends = nodes.map(node => Number(node.dataset.sourceEnd));
    post({type: "selection", text: selection.toString(), lineStart: Math.min(...starts), lineEnd: Math.max(...ends), revision: window.quickMarkview.currentRevision});
  }

  // The DOM selection is the Vim cursor; #cursor only draws its focus end.
  let visual = false, pending = "", saved = null;
  const ESC = "\x1b";

  function rememberSelection() {
    const selection = window.getSelection();
    if (selection.focusNode) saved = [selection.anchorNode, selection.anchorOffset, selection.focusNode, selection.focusOffset];
  }

  function restoreSelection() {
    if (!window.getSelection().focusNode && saved && saved[2].isConnected) window.getSelection().setBaseAndExtent(...saved);
  }

  function drawCursor() {
    const selection = window.getSelection(), mark = document.getElementById("cursor"), node = selection.focusNode;
    const range = document.createRange();
    if (node) range.setStart(node, selection.focusOffset);
    if (node && node.nodeType === 3 && selection.focusOffset < node.length) range.setEnd(node, selection.focusOffset + 1);
    const rect = node && range.getClientRects()[0];
    mark.hidden = !rect;
    if (!rect) return;
    Object.assign(mark.style, {left: `${rect.left + scrollX}px`, top: `${rect.top + scrollY}px`, width: `${Math.max(rect.width, 8)}px`, height: `${rect.height}px`});
    mark.scrollIntoView({block: "nearest"});
  }

  function placeCaret(element) {
    const text = element && document.createTreeWalker(element, NodeFilter.SHOW_TEXT).nextNode();
    if (text) window.getSelection().collapse(text, 0);
  }

  function motion(direction, granularity) {
    window.getSelection().modify(visual ? "extend" : "move", direction, granularity);
  }

  function leaveVisual() {
    const selection = window.getSelection();
    visual = false;
    if (selection.focusNode) selection.collapse(selection.focusNode, selection.focusOffset);
  }

  const bindings = {
    h: () => motion("backward", "character"),
    j: () => motion("forward", "line"),
    k: () => motion("backward", "line"),
    l: () => motion("forward", "character"),
    "0": () => motion("backward", "lineboundary"),
    $: () => motion("forward", "lineboundary"),
    gg: () => motion("backward", "documentboundary"),
    G: () => motion("forward", "documentboundary"),
    v: () => { if (visual) leaveVisual(); else visual = true; },
    [ESC]: leaveVisual,
    " aa": () => post({type: "requestInput"})
  };
  const isPrefix = keys => Object.keys(bindings).some(sequence => sequence.startsWith(keys));

  document.addEventListener("keydown", event => {
    if (event.metaKey || event.ctrlKey || event.altKey || event.isComposing) return;
    const key = event.key === "Escape" ? ESC : event.key;
    if (key.length !== 1) return;
    const keys = isPrefix(pending + key) ? pending + key : key;
    pending = "";
    if (!isPrefix(keys)) return;
    event.preventDefault();
    if (bindings[keys]) bindings[keys](); else pending = keys;
  });
  document.addEventListener("mousedown", () => { visual = false; });
  window.addEventListener("focus", restoreSelection);

  window.quickMarkview = {
    currentLine: null,
    currentRevision: 0,
    renderVersion: 0,
    setDocument: function (source, line, revision) {
      const oldScroll = window.scrollY;
      const version = ++this.renderVersion;
      const env = {};
      const tokens = md.parse(String(source || ""), env);
      document.getElementById("content").innerHTML = md.renderer.render(tokens, md.options, env);
      document.getElementById("toc").innerHTML = tokens.filter(t => t.type === "heading_open").map((open, n) => {
        const inlineToken = tokens[tokens.indexOf(open) + 1], label = inlineToken ? inlineToken.content : "";
        const id = `heading-${open.map ? open.map[0] + 1 : n + 1}`;
        open.attrSet("id", id);
        // The content is already escaped by markdown-it, and this is only a
        // compact navigation label, not a second HTML rendering pass.
        return `<a class="toc-${open.tag.slice(1)}" href="#${id}">${esc(label)}</a>`;
      }).join("");
      // Set heading IDs after rendering because the table of contents above
      // intentionally does not mutate the already rendered token stream.
      tokens.forEach((token, index) => { if (token.type === "heading_open") { const id = `heading-${token.map ? token.map[0] + 1 : index + 1}`; const heading = document.querySelector(`h${token.tag.slice(1)}[data-source-start="${token.map[0] + 1}"]`); if (heading) heading.id = id; } });
      const diagrams = Array.from(document.querySelectorAll(".mermaid"));
      const renders = diagrams.map(container => renderMermaid(container, version));
      this.currentLine = line || null; this.currentRevision = Number(revision || 0);
      Promise.all(renders).then(() => requestAnimationFrame(() => requestAnimationFrame(() => {
        if (version !== this.renderVersion) return;
        let caret;
        if (this.currentLine) caret = this.scrollToLine(this.currentLine);
        else { window.scrollTo(0, oldScroll); caret = Array.from(document.querySelectorAll("[data-source-start]")).find(node => node.getBoundingClientRect().top >= 0); }
        visual = false; placeCaret(caret);
        post({type: "ready", revision: this.currentRevision});
      })));
    },
    scrollToLine: function (line) {
      const wanted = Number(line);
      const mapped = Array.from(document.querySelectorAll("[data-source-start]")).filter(node => Number(node.dataset.sourceStart) <= wanted && Number(node.dataset.sourceEnd) >= wanted);
      const fallback = Array.from(document.querySelectorAll("[data-source-start]")).filter(node => Number(node.dataset.sourceStart) <= wanted).pop();
      const element = mapped[0] || fallback || document.querySelector("[data-source-start]");
      if (element) element.scrollIntoView({block: "start"});
      return element;
    },
    selectedText: sendSelection
  };
  document.addEventListener("selectionchange", () => { rememberSelection(); sendSelection(); drawCursor(); });
})();
