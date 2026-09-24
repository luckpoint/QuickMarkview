(function () {
  "use strict";
  // Rendering libraries are bundled beside this file, so rendering never waits
  // on a network request.
  const md = window.markdownit({html: false, linkify: true, typographer: true});
  const esc = md.utils.escapeHtml;
  mermaid.initialize({startOnLoad: false, securityLevel: "strict"});

  function highlightedCode(source, language) {
    const resolved = hljs.getLanguage(language) ? language : "plaintext";
    return hljs.highlight(source, {language: resolved}).value;
  }

  function wrapHighlightedLines(html, firstLine) {
    const parts = html.split(/(<\/?span\b[^>]*>)/g), stack = [];
    const closeTags = () => stack.map(() => "</span>").reverse().join("");
    const openTags = () => stack.join("");
    let line = firstLine, output = `<span class="line" data-source-start="${line}" data-source-end="${line}">`;
    for (const part of parts) {
      if (part.startsWith("<span")) {
        stack.push(part);
        output += part;
      } else if (part === "</span>") {
        if (stack.length) stack.pop();
        output += part;
      } else {
        const chunks = part.split("\n");
        output += chunks[0];
        for (let index = 1; index < chunks.length; index++) {
          output += closeTags() + "</span>\n";
          line++;
          output += `<span class="line" data-source-start="${line}" data-source-end="${line}">` + openTags() + chunks[index];
        }
      }
    }
    return output + closeTags() + "</span>";
  }

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
    if (language && hljs.getLanguage(language)) {
      return `<pre data-source-start="${start}" data-source-end="${end}"><code class="hljs language-${esc(language)}">${hljs.highlight(token.content, {language}).value}</code></pre>\n`;
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
  // In V mode the selection spans whole rendered lines, so the cursor is kept apart.
  let mode = "", pending = "", saved = null, cursor = null, lineAnchor = null;
  const ESC = "\x1b", controlFollow = "\x1d", controlBack = "\x1e";
  const controls = {f: "\x06", b: "\x02", "]": controlFollow, "}": controlFollow, "^": controlBack, "6": controlBack};

  function caret() {
    const selection = window.getSelection();
    return [selection.focusNode, selection.focusOffset];
  }

  function rememberSelection() {
    const selection = window.getSelection();
    if (selection.focusNode) saved = [selection.anchorNode, selection.anchorOffset, selection.focusNode, selection.focusOffset];
  }

  function restoreSelection() {
    if (!window.getSelection().focusNode && saved && saved[2].isConnected) window.getSelection().setBaseAndExtent(...saved);
  }

  function rectAt([node, offset]) {
    if (!node) return null;
    const range = document.createRange();
    range.setStart(node, offset);
    if (node.nodeType === 3 && offset < node.length) range.setEnd(node, offset + 1);
    return range.getClientRects()[0] || null;
  }

  const cursorRect = () => rectAt(mode === "V" ? cursor : caret());

  function drawCursor() {
    const mark = document.getElementById("cursor"), rect = cursorRect();
    mark.hidden = !rect;
    if (!rect) return;
    Object.assign(mark.style, {left: `${rect.left + scrollX}px`, top: `${rect.top + scrollY}px`, width: `${Math.max(rect.width, 8)}px`, height: `${rect.height}px`});
    mark.scrollIntoView({block: "nearest"});
  }

  function placeCaret(element) {
    const text = element && document.createTreeWalker(element, NodeFilter.SHOW_TEXT).nextNode();
    if (text) window.getSelection().collapse(text, 0);
  }

  function linkAtCaret() {
    const [node] = caret();
    let element = node && (node.nodeType === 3 ? node.parentElement : node);
    return element && element.closest ? element.closest("a[href]") : null;
  }

  function followLink(anchor) {
    const href = anchor.getAttribute("href") || "";
    if (/^(https?:|mailto:)/i.test(href) || href.startsWith("//")) return false;
    if (href.startsWith("#")) return false;
    const block = anchor.closest("[data-source-start]");
    post({type: "openLink", href, fromLine: Number(block && block.dataset.sourceStart) || 1});
    return true;
  }

  function visibleLine() {
    const visible = Array.from(document.querySelectorAll("[data-source-start]"))
      .filter(node => node.getBoundingClientRect().bottom >= 0)
      .sort((a, b) => a.getBoundingClientRect().top - b.getBoundingClientRect().top)[0];
    return Number(visible && visible.dataset.sourceStart) || 1;
  }

  // Expands the collapsed selection to the rendered line it sits on.
  function currentLine() {
    const selection = window.getSelection();
    selection.modify("move", "backward", "lineboundary");
    const start = caret();
    selection.modify("move", "forward", "lineboundary");
    return [start, caret()];
  }

  function isBefore(a, b) {
    const range = document.createRange();
    range.setStart(...b);
    return range.comparePoint(...a) < 0;
  }

  function selectLines() {
    cursor = caret();
    const [start, end] = currentLine(), down = !isBefore(start, lineAnchor[0]);
    window.getSelection().setBaseAndExtent(...(down ? lineAnchor[0] : lineAnchor[1]), ...(down ? end : start));
  }

  function enterLineVisual() {
    const selection = window.getSelection(), focus = caret();
    if (!focus[0]) return;
    selection.collapse(selection.anchorNode, selection.anchorOffset);
    lineAnchor = currentLine();
    selection.collapse(...focus);
    mode = "V";
    selectLines();
  }

  function move(step) {
    const selection = window.getSelection();
    if (mode === "V") selection.collapse(...cursor);
    step(selection, mode === "v" ? "extend" : "move");
    if (mode === "V") selectLines();
  }

  const motion = (direction, granularity) => move((selection, alter) => selection.modify(alter, direction, granularity));

  // Scrolls half a page and moves the cursor by lines until it has covered the same distance.
  function halfPage(sign) {
    const distance = sign * window.innerHeight / 2, rect = cursorRect(), target = rect && rect.top + window.scrollY + distance;
    window.scrollBy(0, distance);
    if (!rect) return;
    const reached = point => { const next = rectAt(point); return next && sign * (next.top + window.scrollY - target) >= 0; };
    move((selection, alter) => {
      for (let point = caret(); !reached(point);) {
        selection.modify(alter, sign > 0 ? "forward" : "backward", "line");
        const next = caret();
        if (next[0] === point[0] && next[1] === point[1]) return;
        point = next;
      }
    });
  }

  function leaveVisual() {
    const [node, offset] = mode === "V" ? cursor : caret();
    mode = "";
    if (node) window.getSelection().collapse(node, offset);
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
    [controls.f]: () => halfPage(1),
    [controls.b]: () => halfPage(-1),
    [controlFollow]: () => { const anchor = linkAtCaret(); if (anchor && !followLink(anchor)) anchor.click(); },
    [controlBack]: () => post({type: "back", fromLine: visibleLine()}),
    v: () => { if (mode === "v") leaveVisual(); else mode = "v"; },
    V: () => { if (mode === "V") leaveVisual(); else enterLineVisual(); },
    [ESC]: leaveVisual,
    " aa": () => post({type: "requestInput"})
  };
  const isPrefix = keys => Object.keys(bindings).some(sequence => sequence.startsWith(keys));

  document.addEventListener("keydown", event => {
    if (event.metaKey || event.altKey || event.isComposing) return;
    const key = event.key === "Tab" && !event.shiftKey ? TAB : event.key === "Escape" ? ESC : event.ctrlKey ? controls[event.key] : event.key;
    if (!key || key.length !== 1) return;
    const keys = isPrefix(pending + key) ? pending + key : key;
    pending = "";
    if (!isPrefix(keys)) return;
    event.preventDefault();
    if (bindings[keys]) bindings[keys](); else pending = keys;
  });
  document.addEventListener("click", event => {
    const anchor = event.target instanceof Element ? event.target.closest("a[href]") : null;
    if (anchor && followLink(anchor)) event.preventDefault();
  });
  document.addEventListener("mousedown", () => { mode = ""; });
  window.addEventListener("focus", restoreSelection);

  window.quickMarkview = {
    currentLine: null,
    currentRevision: 0,
    renderVersion: 0,
    imagesReady: Promise.resolve(),
    resolveImagesReady: null,
    setImageSources: function (revision, sources) {
      if (Number(revision) !== this.currentRevision) return;
      const images = Array.from(document.querySelectorAll("img"));
      images.forEach(image => {
        const source = image.getAttribute("src");
        if (source && sources[source]) image.src = sources[source];
      });
      const pending = images.filter(image => image.src.startsWith("data:") && !image.complete)
        .map(image => new Promise(resolve => { image.onload = image.onerror = resolve; }));
      Promise.all(pending).then(() => {
        if (this.resolveImagesReady) { this.resolveImagesReady(); this.resolveImagesReady = null; }
      });
    },
    setDocument: function (source, line, revision, language) {
      const oldScroll = window.scrollY;
      const version = ++this.renderVersion;
      const env = {};
      const text = String(source || "");
      const tokens = language === null || language === undefined ? md.parse(text, env) : null;
      const content = document.getElementById("content");
      const toc = document.getElementById("toc");
      if (language !== null && language !== undefined) {
        const html = highlightedCode(text, language);
        content.innerHTML = `<pre><code class="hljs language-${esc(hljs.getLanguage(language) ? language : "plaintext")}">${wrapHighlightedLines(html, 1)}</code></pre>`;
        toc.innerHTML = "";
      } else {
        content.innerHTML = md.renderer.render(tokens, md.options, env);
      }
      this.currentRevision = Number(revision || 0);
      if (tokens) {
        const sources = imageSources(tokens);
        if (sources.length) {
          this.imagesReady = new Promise(resolve => { this.resolveImagesReady = resolve; });
          post({type: "resolveImages", sources, revision: this.currentRevision});
        } else this.imagesReady = Promise.resolve();
      }
      toc.innerHTML = tokens ? tokens.filter(t => t.type === "heading_open").map((open, n) => {
        const inlineToken = tokens[tokens.indexOf(open) + 1], label = inlineToken ? inlineToken.content : "";
        const id = `heading-${open.map ? open.map[0] + 1 : n + 1}`;
        open.attrSet("id", id);
        // The content is already escaped by markdown-it, and this is only a
        // compact navigation label, not a second HTML rendering pass.
        return `<a class="toc-${open.tag.slice(1)}" href="#${id}">${esc(label)}</a>`;
      }).join("") : "";
      // Set heading IDs after rendering because the table of contents above
      // intentionally does not mutate the already rendered token stream.
      if (tokens) tokens.forEach((token, index) => { if (token.type === "heading_open") { const id = `heading-${token.map ? token.map[0] + 1 : index + 1}`; const heading = document.querySelector(`h${token.tag.slice(1)}[data-source-start="${token.map[0] + 1}"]`); if (heading) heading.id = id; } });
      const diagrams = Array.from(document.querySelectorAll(".mermaid"));
      const renders = diagrams.map(container => renderMermaid(container, version));
      this.currentLine = line || null; this.currentRevision = Number(revision || 0);
      Promise.all(renders).then(() => requestAnimationFrame(() => requestAnimationFrame(() => {
        if (version !== this.renderVersion) return;
        let caret;
        if (this.currentLine) caret = this.scrollToLine(this.currentLine);
        else { window.scrollTo(0, oldScroll); caret = Array.from(document.querySelectorAll("[data-source-start]")).find(node => node.getBoundingClientRect().top >= 0); }
        mode = ""; placeCaret(caret);
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
    toggleSidebar: function () {
      const toc = document.getElementById("toc");
      toc.hidden = !toc.hidden;
      drawCursor();
    },
    visibleLine: visibleLine,
    selectedText: sendSelection
  };
  document.addEventListener("selectionchange", () => { rememberSelection(); sendSelection(); drawCursor(); });
})();
