/* Viewer page logic. Injected by the app as a WKUserScript; the app calls FLICK.render(html, ...). */
(() => {
  'use strict';

  const CONFIG = window.__FLICK__ || {};
  const RES = CONFIG.res || '';
  const ZH = CONFIG.lang === 'zh';

  const content = document.getElementById('flick-content');
  const tocBox = document.getElementById('flick-toc');
  const tocList = document.getElementById('flick-toc-list');
  const baseEl = document.getElementById('flick-base');
  document.getElementById('flick-toc-title').textContent = ZH ? '目录' : 'CONTENTS';

  const ALERT_TITLES = ZH
    ? { note: '备注', tip: '提示', important: '重要', warning: '警告', caution: '注意' }
    : { note: 'Note', tip: 'Tip', important: 'Important', warning: 'Warning', caution: 'Caution' };

  const post = (msg) => window.webkit?.messageHandlers?.flick?.postMessage(msg);

  let generation = 0;
  let headings = [];
  let tocLinks = [];
  let activeIndex = -1;
  let slugs = new Map();
  // Long documents arrive as several HTML pieces; all but the first are attached after the first paint.
  let queue = [];
  let streaming = false;
  let moreExpected = false;
  let firstFrameDone = false;
  let renderStart = 0;
  let spyList = null; // cached outline-tracking targets for the current view

  // ---------------------------------------------------------------------------
  // Lazily loaded renderers: nothing beyond this file is parsed unless the document needs it.

  const loaded = new Map();
  function loadScript(path) {
    if (!loaded.has(path)) {
      loaded.set(path, new Promise((resolve, reject) => {
        const s = document.createElement('script');
        s.src = RES + path;
        s.onload = resolve;
        s.onerror = () => reject(new Error('failed to load ' + path));
        document.head.appendChild(s);
      }));
    }
    return loaded.get(path);
  }
  function loadStyle(path, media) {
    if (loaded.has(path)) return;
    loaded.set(path, true);
    const link = document.createElement('link');
    link.rel = 'stylesheet';
    link.href = RES + path;
    if (media) link.media = media;
    document.head.appendChild(link);
  }

  let hljsReady;
  function highlight(code) {
    hljsReady ||= (() => {
      loadStyle('vendor/hljs/github.min.css', '(prefers-color-scheme: light)');
      loadStyle('vendor/hljs/github-dark.min.css', '(prefers-color-scheme: dark)');
      return loadScript('vendor/hljs/highlight.min.js').then(() => hljs.configure({ ignoreUnescapedHTML: true }));
    })();
    hljsReady.then(() => {
      if (hljs.getLanguage(code.dataset.lang)) hljs.highlightElement(code);
    });
  }

  let katexReady;
  function renderMath(el, displayMode) {
    katexReady ||= (loadStyle('vendor/katex/katex.min.css'), loadScript('vendor/katex/katex.min.js'));
    katexReady.then(() => {
      katex.render(el.textContent, el, { displayMode, throwOnError: false });
      el.classList.add('flick-done');
    });
  }

  let mermaidReady;
  let mermaidSeq = 0;
  function renderMermaid(el) {
    mermaidReady ||= loadScript('vendor/mermaid/mermaid.min.js').then(() => {
      const dark = matchMedia('(prefers-color-scheme: dark)').matches;
      mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', theme: dark ? 'dark' : 'default' });
    });
    const id = 'flick-mermaid-' + (++mermaidSeq);
    mermaidReady
      .then(() => mermaid.render(id, el.textContent))
      .then(({ svg }) => {
        el.innerHTML = svg;
        el.classList.add('flick-done');
      })
      .catch((err) => {
        document.getElementById('d' + id)?.remove();
        el.classList.add('flick-error');
        el.title = String(err?.message || err);
      });
  }

  // Enhance blocks only as they approach the viewport.
  const observer = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      if (!entry.isIntersecting) continue;
      const el = entry.target;
      observer.unobserve(el);
      switch (el.dataset.flick) {
        case 'code': highlight(el); break;
        case 'math': renderMath(el, el.getAttribute('type') === 'display'); break;
        case 'math-block': renderMath(el, true); break;
        case 'mermaid': renderMermaid(el); break;
      }
    }
  }, { rootMargin: '1500px 0px' });

  // ---------------------------------------------------------------------------
  // Preview position -> source line when the preview has no line marks yet (it was rendered for
  // reading). Used once when switching to the editor: match headings to their source lines.

  const FENCE = /^ {0,3}(`{3,}|~{3,})/;
  const closesFence = (s, f, open) => f && f[1][0] === open[0] && f[1].length >= open.length && !s.slice(f[0].length).trim();

  /** Source line (0-based) of each entry in `headings`, or -1 when it can't be located. */
  function headingLines(lines) {
    const found = [];
    const blockStart = /^\s*([-*+>#|]|\d{1,9}[.)]|`{3}|~{3})/;
    let fence = null;
    for (let i = 0; i < lines.length; i++) {
      const s = lines[i];
      const f = FENCE.exec(s);
      if (fence) {
        if (closesFence(s, f, fence)) fence = null;
        continue;
      }
      if (f) fence = f[1];
      else if (/^ {0,3}#{1,6}(\s|$)/.test(s) || /^\s*<h[1-6][\s>]/i.test(s)) found.push(i);
      else if (i > 0 && /^ {0,3}(=+|-+)\s*$/.test(s) && lines[i - 1].trim() && !blockStart.test(lines[i - 1])) found.push(i - 1);
    }
    if (found.length === headings.length) return found;
    // Counts differ (e.g. unusual heading syntax): match by text, in order.
    const norm = (t) => t.toLowerCase().replace(/[^\p{L}\p{N}]/gu, '');
    const map = [];
    let j = 0;
    for (const h of headings) {
      const want = norm(h.textContent);
      let k = j;
      while (k < found.length && k < j + 50 && !(want && norm(lines[found[k]]).includes(want))) k++;
      if (k < found.length && k < j + 50) {
        map.push(found[k]);
        j = k + 1;
      } else {
        map.push(-1);
      }
    }
    return map;
  }

  /** The source line at the top of the preview, interpolated between the surrounding headings. */
  function headingTopLine(text) {
    const lines = text.replace(/^\uFEFF/, '').split(/\r\n|\r|\n/);
    const marks = [];
    headingLines(lines).forEach((ln, i) => { if (ln >= 0) marks.push({ ln, y: headings[i].getBoundingClientRect().top + window.scrollY }); });
    const y = window.scrollY;
    let k = -1;
    while (k + 1 < marks.length && marks[k + 1].y <= y + 1) k++;
    const start = k < 0 ? 0 : marks[k].y;
    const end = k + 1 < marks.length ? marks[k + 1].y : document.documentElement.scrollHeight;
    const la = k >= 0 ? marks[k].ln + 1 : 1;
    const lb = k + 1 < marks.length ? marks[k + 1].ln + 1 : lines.length + 1;
    return la + (end > start ? (y - start) / (end - start) : 0) * (lb - la);
  }

  // ---------------------------------------------------------------------------
  // Render

  // GitHub-compatible heading anchors, so links like [x](#安装说明) work.
  const slugify = (text) =>
    text.trim().toLowerCase().replace(/[^\p{L}\p{M}\p{N}\p{Pc}\- ]/gu, '').replace(/ /g, '-');

  function replaceBlock(pre, className, text, kind, pending) {
    const div = document.createElement('div');
    if (pre.dataset.l) div.dataset.l = pre.dataset.l;
    div.className = className;
    div.textContent = text;
    div.dataset.flick = kind;
    pre.replaceWith(div);
    pending.push(div);
  }

  function parse(html) {
    const tpl = document.createElement('template');
    tpl.innerHTML = html; // parsed inert: no layout, no image loads, no scripts
    return tpl.content;
  }

  /** Fixes up a parsed (still inert) fragment and returns the elements to enhance lazily. */
  function prepare(frag) {
    const pending = [];
    for (const h of frag.querySelectorAll('h1, h2, h3, h4, h5, h6')) {
      headings.push(h);
      if (h.id) continue;
      const slug = slugify(h.textContent) || 'section';
      const n = slugs.get(slug) || 0;
      slugs.set(slug, n + 1);
      h.id = n ? `${slug}-${n}` : slug;
    }
    for (const img of frag.querySelectorAll('img')) {
      img.loading = 'lazy';
      img.decoding = 'async';
    }
    for (const code of frag.querySelectorAll('pre > code')) {
      const m = /(?:^|\s)language-(\S+)/.exec(code.className);
      if (!m) continue;
      const lang = m[1].toLowerCase();
      if (lang === 'mermaid') replaceBlock(code.parentElement, 'flick-mermaid', code.textContent, 'mermaid', pending);
      else if (lang === 'math') replaceBlock(code.parentElement, 'flick-math-block', code.textContent, 'math-block', pending);
      else {
        code.dataset.lang = lang;
        code.dataset.flick = 'code';
        pending.push(code);
      }
    }
    for (const eq of frag.querySelectorAll('x-equation')) {
      eq.dataset.flick = 'math';
      pending.push(eq);
    }
    // md4c emits <div class="admonition-NOTE"><p class="admonition-title">NOTE</p>…
    for (const div of frag.querySelectorAll('div[class^="admonition-"]')) {
      const type = div.className.slice('admonition-'.length).toLowerCase();
      div.className = 'flick-alert flick-alert-' + type;
      const title = div.querySelector(':scope > .admonition-title');
      if (title) title.textContent = ALERT_TITLES[type] || type;
    }
    return pending;
  }

  function buildTOC() {
    const frag = document.createDocumentFragment();
    const min = headings.reduce((m, h) => Math.min(m, +h.tagName[1]), 6);
    tocLinks = headings.map((h, i) => {
      const a = document.createElement('a');
      a.setAttribute('href', '#' + h.id);
      a.textContent = h.textContent.trim();
      a.title = a.textContent;
      a.dataset.l = String(+h.tagName[1] - min + 1);
      a.dataset.i = String(i);
      frag.appendChild(a);
      return a;
    });
    tocList.replaceChildren(frag);
    document.body.classList.toggle('flick-has-toc', headings.length > 1);
    activeIndex = -1;
  }

  const afterFrame = (fn) => requestAnimationFrame(() => setTimeout(fn, 0));
  const observeAll = (els) => { for (const el of els) if (el.dataset.flick) observer.observe(el); };

  /**
   * o.base: the document's folder URL; o.keep: keep the scroll position (reload); o.toc: show the outline;
   * o.more: further pieces follow via append();
   * o.line/o.total: the editor's top line and line count, to scroll the preview to match it.
   */
  function render(html, o) {
    const { base, keep: keepScroll, toc: showTOC, more, line, total } = o;
    const t0 = performance.now();
    const gen = ++generation;
    const y = window.scrollY;
    const tocY = tocBox.scrollTop;
    renderStart = t0;
    headings = [];
    slugs = new Map();
    queue = [];
    streaming = moreExpected = !!more;
    firstFrameDone = false;
    spyList = null;
    blockLines = null;
    observer.disconnect();

    baseEl.setAttribute('href', base); // relative images and links resolve against the document's folder
    const frag = parse(html);
    const pending = prepare(frag);
    content.replaceChildren(frag);
    buildTOC();
    setTOC(showTOC);


    tocBox.scrollTop = keepScroll ? tocY : 0;
    void content.offsetHeight; // lay out now so the first frame only has to paint
    if (line != null) syncTo(line, total);
    else window.scrollTo(0, keepScroll ? y : 0);
    updateActive();

    // Everything else waits until the first frame is on screen: the rest of a long document,
    // then syntax highlighting / KaTeX / Mermaid for blocks near the viewport.
    const startedAt = Date.now() - (performance.now() - t0);
    afterFrame(() => {
      if (gen !== generation) return;
      firstFrameDone = true;
      post({ type: 'painted', start: startedAt, frame: Date.now() });
      observeAll(pending);
      if (streaming) schedulePump();
    });
    return { ms: +(performance.now() - t0).toFixed(2), blocks: content.childElementCount, headings: headings.length };
  }

  /** The remaining pieces of the document passed to the last render(). */
  function append(chunks) {
    queue.push(...chunks);
    moreExpected = false;
    schedulePump();
  }

  let pumpScheduled = false;
  function schedulePump() {
    if (pumpScheduled || !firstFrameDone) return;
    pumpScheduled = true;
    const gen = generation;
    afterFrame(() => {
      pumpScheduled = false;
      if (gen === generation) pumpOne();
    });
  }

  // One piece per frame keeps scrolling responsive while a long document finishes loading.
  function pumpOne() {
    const html = queue.shift();
    if (html !== undefined) {
      const frag = parse(html);
      const pending = prepare(frag);
      content.appendChild(frag);
      observeAll(pending);
      spyList = null;
      blockLines = null;
    }
    if (queue.length) {
      schedulePump();
    } else if (streaming && !moreExpected) {
      streaming = false;
      buildTOC();
      updateActive();
      post({ type: 'complete', ms: Math.round(performance.now() - renderStart), blocks: content.childElementCount });
    }
  }

  function setTOC(show) {
    document.body.classList.toggle('flick-toc-open', !!show);
  }

  // ---------------------------------------------------------------------------
  // Edit mode: preview position <-> source line, using the data-l line marks on top-level blocks.

  let editing = false;
  let blockLines = null; // [{ line, el }] in document order
  let totalLines = 1;
  let echoUntil = 0; // scroll events before this time come from syncTo(), not the user

  function blockMarks() {
    if (!blockLines) {
      blockLines = [];
      for (const el of content.querySelectorAll('[data-l]')) {
        const line = +el.dataset.l;
        if (line > 0 && (!blockLines.length || line > blockLines[blockLines.length - 1].line)) blockLines.push({ line, el });
      }
    }
    return blockLines;
  }

  // y of mark i, or of the nearest rendered mark in direction `step` (content of a closed <details> has no box).
  function markY(marks, i, step) {
    for (; i >= 0 && i < marks.length; i += step) {
      const el = marks[i].el;
      if (el.getClientRects().length) return { i, y: el.getBoundingClientRect().top + window.scrollY };
    }
    return null;
  }

  function span(marks, k) {
    const a = k >= 0 ? markY(marks, k, -1) : null;
    const b = markY(marks, k + 1, 1);
    return {
      la: a ? marks[a.i].line : 1, ya: a ? a.y : 0,
      lb: b ? marks[b.i].line : totalLines + 1, yb: b ? b.y : document.documentElement.scrollHeight,
    };
  }

  /** Scrolls the preview so that source line `line` (1-based, fractional) is at the top. */
  function syncTo(line, total) {
    if (total) totalLines = total;
    const marks = blockMarks();
    let y = 0;
    if (marks.length && line > 1.001) {
      let lo = 0, hi = marks.length - 1, k = -1;
      while (lo <= hi) {
        const mid = (lo + hi) >> 1;
        if (marks[mid].line <= line) { k = mid; lo = mid + 1; } else hi = mid - 1;
      }
      const { la, ya, lb, yb } = span(marks, k);
      y = lb > la ? ya + ((line - la) / (lb - la)) * (yb - ya) : ya;
    }
    echoUntil = performance.now() + 150;
    window.scrollTo(0, y);
  }

  /** The source line at the top of the preview, interpolated between marked blocks. */
  function previewTopLine() {
    const marks = blockMarks();
    const y = window.scrollY;
    if (!marks.length || y <= 0) return 1;
    let lo = 0, hi = marks.length - 1, k = -1;
    while (lo <= hi) {
      const mid = (lo + hi) >> 1;
      const p = markY(marks, mid, 1);
      if (p && p.y <= y) { k = p.i; lo = p.i + 1; } else hi = mid - 1;
    }
    const { la, ya, lb, yb } = span(marks, k);
    return la + (yb > ya ? (y - ya) / (yb - ya) : 0) * (lb - la);
  }

  /** The source line at the top of the preview; used when switching to the editor. */
  function topLine(text) {
    return blockMarks().length ? previewTopLine() : headingTopLine(text || '');
  }

  function setEditing(on) {
    editing = !!on;
  }

  // ---------------------------------------------------------------------------
  // Find in page. Matches may span inline formatting ("foo **bar**"); every match is highlighted with
  // the CSS Custom Highlight API, so the document itself is never modified.

  const FIND_LIMIT = 10000;
  const BLOCK_TAGS = new Set(['P', 'LI', 'H1', 'H2', 'H3', 'H4', 'H5', 'H6', 'PRE', 'BLOCKQUOTE', 'TD', 'TH', 'TR',
    'DIV', 'DT', 'DD', 'SECTION', 'DETAILS', 'SUMMARY', 'FIGCAPTION', 'TABLE', 'UL', 'OL', 'HR', 'BR']);
  const NOT_SEARCHED = '.katex, svg, script, style'; // rendered math and diagrams are not searchable text
  const hasHighlights = !!(window.Highlight && CSS.highlights);
  const allMatches = hasHighlights ? new Highlight() : null;
  const currentMatch = hasHighlights ? new Highlight() : null;
  if (hasHighlights) {
    CSS.highlights.set('flick-find', allMatches);
    CSS.highlights.set('flick-find-current', currentMatch);
  }
  const finder = { text: null, nodes: [], starts: [], query: '', matches: [], ranges: [], current: -1 };

  // All text of the document in one string, with a newline between blocks, plus where each text node starts.
  function findIndex() {
    if (finder.text !== null) return;
    const nodes = [];
    const starts = [];
    let text = '';
    const walker = document.createTreeWalker(content, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
      acceptNode: (n) => (n.nodeType === 1 && n.matches(NOT_SEARCHED) ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT),
    });
    for (let n; (n = walker.nextNode());) {
      if (n.nodeType === 1) {
        if (BLOCK_TAGS.has(n.tagName)) text += '\n';
        continue;
      }
      nodes.push(n);
      starts.push(text.length);
      text += n.data;
    }
    Object.assign(finder, { text, nodes, starts });
  }

  function textPosition(offset, isEnd) {
    const { starts, nodes } = finder;
    let lo = 0, hi = starts.length - 1, k = 0;
    while (lo <= hi) {
      const mid = (lo + hi) >> 1;
      if (isEnd ? starts[mid] < offset : starts[mid] <= offset) { k = mid; lo = mid + 1; } else hi = mid - 1;
    }
    return [nodes[k], Math.min(offset - starts[k], nodes[k].length)];
  }

  function searchMatches() {
    findIndex();
    finder.matches = [];
    finder.ranges = [];
    allMatches?.clear();
    currentMatch?.clear();
    if (!finder.query || !finder.nodes.length) return;
    const re = new RegExp(finder.query.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'giu');
    for (let m; finder.matches.length < FIND_LIMIT && (m = re.exec(finder.text));) {
      if (!m[0].length) { re.lastIndex++; continue; }
      const range = document.createRange();
      range.setStart(...textPosition(m.index, false));
      range.setEnd(...textPosition(m.index + m[0].length, true));
      finder.matches.push(m.index);
      finder.ranges.push(range);
      allMatches?.add(range);
    }
  }

  // First match at or below the top of the viewport.
  function firstVisibleMatch() {
    const ranges = finder.ranges;
    let lo = 0, hi = ranges.length - 1, k = -1;
    while (lo <= hi) {
      const mid = (lo + hi) >> 1;
      if (ranges[mid].getBoundingClientRect().bottom >= 0) { k = mid; hi = mid - 1; } else lo = mid + 1;
    }
    return k >= 0 ? k : ranges.length ? 0 : -1; // all above the viewport: wrap to the first
  }

  function showCurrent(scroll) {
    currentMatch?.clear();
    const range = finder.ranges[finder.current];
    if (!range) return;
    if (currentMatch) currentMatch.add(range);
    else { const sel = getSelection(); sel.removeAllRanges(); sel.addRange(range); }
    if (!scroll) return;
    const node = range.startContainer.parentElement;
    const closed = node?.closest('details:not([open])');
    if (closed) closed.open = true;
    // Wide code blocks and tables scroll sideways on their own.
    const box = node?.closest('pre, table');
    let r = range.getBoundingClientRect();
    if (box) {
      const b = box.getBoundingClientRect();
      if (r.left < b.left + 20 || r.right > b.right - 20) {
        box.scrollLeft += r.left - b.left - b.width / 3;
        r = range.getBoundingClientRect();
      }
    }
    if (r.top < 40 || r.bottom > window.innerHeight - 40) window.scrollTo(0, window.scrollY + r.top - window.innerHeight / 3);
  }

  function findResult() {
    const result = { count: finder.matches.length, current: finder.current + 1, capped: finder.matches.length >= FIND_LIMIT };
    post({ type: 'find', ...result });
    return result;
  }

  /** direction 0: new search from the top of the viewport; 1: next match; -1: previous match. */
  function find(query, direction) {
    if (query !== finder.query || direction === 0) {
      finder.query = query;
      searchMatches();
      finder.current = firstVisibleMatch();
      if (direction === -1 && finder.current >= 0) finder.current = (finder.current - 1 + finder.matches.length) % finder.matches.length;
    } else if (finder.matches.length) {
      finder.current = (finder.current + direction + finder.matches.length) % finder.matches.length;
    }
    showCurrent(true);
    return findResult();
  }

  function endFind() {
    finder.query = '';
    finder.matches = [];
    finder.ranges = [];
    finder.current = -1;
    allMatches?.clear();
    currentMatch?.clear();
  }

  const selectedText = () => String(getSelection()).trim().slice(0, 200);

  // Highlighting, KaTeX, Mermaid, streamed pieces and re-renders all change the text nodes: re-run an
  // active search on the new DOM, keeping the current match number.
  let findRefresh = 0;
  new MutationObserver(() => {
    finder.text = null;
    if (!finder.query) return;
    clearTimeout(findRefresh);
    findRefresh = setTimeout(() => {
      const keep = finder.current;
      searchMatches();
      finder.current = finder.matches.length ? Math.min(Math.max(keep, 0), finder.matches.length - 1) : -1;
      showCurrent(false);
      findResult();
    }, 150);
  }).observe(content, { childList: true, subtree: true, characterData: true });

  // ---------------------------------------------------------------------------
  // Outline tracking and in-page links

  let spyQueued = false;
  function onScroll() {
    if (spyQueued) return;
    spyQueued = true;
    requestAnimationFrame(() => {
      spyQueued = false;
      updateActive();
      if (editing && performance.now() > echoUntil) post({ type: 'line', line: previewTopLine() });
    });
  }

  function spyTargets() {
    spyList ||= headings.map((el, i) => ({ i, el }));
    return spyList;
  }

  function updateActive() {
    // Last heading above the top 25% of the viewport; binary search keeps this O(log n).
    const list = spyTargets();
    const line = Math.min(120, window.innerHeight * 0.25);
    let lo = 0, hi = list.length - 1, found = -1;
    while (lo <= hi) {
      const mid = (lo + hi) >> 1;
      if (list[mid].el.getBoundingClientRect().top <= line) { found = mid; lo = mid + 1; } else hi = mid - 1;
    }
    const idx = found >= 0 ? list[found].i : -1;
    if (idx === activeIndex) return;
    tocLinks[activeIndex]?.classList.remove('active');
    activeIndex = idx;
    const link = tocLinks[idx];
    if (!link) return;
    link.classList.add('active');
    const top = link.offsetTop;
    if (top < tocBox.scrollTop + 40 || top + link.offsetHeight > tocBox.scrollTop + tocBox.clientHeight - 40) {
      tocBox.scrollTop = top - tocBox.clientHeight / 3;
    }
  }

  function jump(id) {
    const el = document.getElementById(id) || document.getElementsByName(id)[0];
    if (el) el.scrollIntoView({ block: 'start' });
  }

  // With <base> pointing at the document folder, "#x" would resolve to another URL; handle it here.
  document.addEventListener('click', (e) => {
    const a = e.target.closest?.('a[href]');
    const href = a?.getAttribute('href');
    if (!href || !href.startsWith('#')) return;
    e.preventDefault();
    try { jump(decodeURIComponent(href.slice(1))); } catch { jump(href.slice(1)); }
  });

  window.addEventListener('scroll', onScroll, { passive: true });
  window.addEventListener('resize', onScroll, { passive: true });

  window.FLICK = { render, append, setTOC, jump, setEditing, syncTo, topLine, find, endFind, selectedText };
  post({ type: 'ready' });
})();
