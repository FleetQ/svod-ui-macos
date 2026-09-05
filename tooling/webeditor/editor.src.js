// Svod web editor — CodeMirror 6 (edit) + markdown-it/highlight.js/mermaid (preview).
// Bundled to a single IIFE via esbuild; loaded by editor.html inside a WKWebView.
// Bridges to Swift through window.webkit.messageHandlers.svod and window.SvodEditor.

import { EditorView, keymap, drawSelection, highlightActiveLine,
         highlightActiveLineGutter, lineNumbers, Decoration, ViewPlugin } from "@codemirror/view";
import { EditorState, Compartment } from "@codemirror/state";
import { defaultKeymap, history, historyKeymap, indentWithTab } from "@codemirror/commands";
import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { HighlightStyle, syntaxHighlighting, bracketMatching, indentOnInput,
         foldGutter, foldKeymap, LanguageDescription } from "@codemirror/language";
import { languages } from "@codemirror/language-data";
import { searchKeymap, highlightSelectionMatches } from "@codemirror/search";
import { autocompletion, completionKeymap } from "@codemirror/autocomplete";
import { tags as t } from "@lezer/highlight";
import MarkdownIt from "markdown-it";
import hljs from "highlight.js";
import mermaid from "mermaid";

// ── Swift bridge ──────────────────────────────────────────────────────────
const post = (msg) => { try { window.webkit.messageHandlers.svod.postMessage(msg); } catch (e) {} };

// ── State ─────────────────────────────────────────────────────────────────
let view = null;
let applyingExternal = false;          // suppress change events while Swift sets content
let dark = true;
let noteNames = new Set();              // lowercased, for [[wikilink]] resolution
let noteNamesList = [];                 // original-case, for [[ autocomplete
const themeC = new Compartment();
const hlC = new Compartment();
const langC = new Compartment();

// The open file, so both panes can treat a non-markdown file as code. A vault note is
// markdown; a `.py`/`.php`/… synced in from an external source is not, and running it
// through markdown-it collapses its newlines into prose.
let currentFilename = "";


// Palette — seeded with Svod dark tokens; overridden by configure() from Swift.
let C = {
  editorSurface: "#14161B", surface: "#1E222A", textPrimary: "#ECEDEF",
  textSecondary: "#A8AEB8", textTertiary: "#767C87", accent: "#6FA0E6",
  link: "#7FB0EE", linkUnresolved: "#C08A6E", borderSubtle: "#2E343E",
  surfaceHover: "#232831", selection: "#243042", string: "#5BC2B0",
  heading: "#ECEDEF", emphasis: "#ECEDEF", code: "#6FA0E6",
};

// ── markdown-it (preview) ───────────────────────────────────────────────────
const md = new MarkdownIt({
  html: false, linkify: true, breaks: false,
  highlight(str, lang) {
    if (lang === "mermaid") return `<div class="mermaid">${escapeHtml(str)}</div>`;
    if (lang && hljs.getLanguage(lang)) {
      try { return `<pre class="code"><code class="hljs">${hljs.highlight(str, { language: lang }).value}</code></pre>`; } catch (e) {}
    }
    return `<pre class="code"><code class="hljs">${escapeHtml(str)}</code></pre>`;
  },
});

function escapeHtml(s) {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

// GFM tables split each row on `|`, which would tear a [[target|alias]] wikilink across
// two cells. Swap the alias pipe to a private-use sentinel before parsing so the table
// tokenizer ignores it; the wikilink inline rule restores it. (A `|` only ever appears
// inside [[...]] as the alias separator.)
const WL_PIPE = "";
function protectWikilinkPipes(src) {
  return src.replace(/\[\[[^\n\]]*\]\]/g, (m) => m.replace(/\|/g, WL_PIPE));
}

// Resolve a same-vault [[target]] against the known note names.
function isResolved(target) {
  if (!target) return false;
  if (target.includes(":")) return true;             // cross-vault [[vault:note]] — link out
  const norm = target.replace(/\.md$/i, "").trim().toLowerCase();
  return noteNames.has(norm);
}

// markdown-it inline rule for [[target]] / [[target|alias]] / [[vault:note]].
md.inline.ruler.before("link", "wikilink", (state, silent) => {
  const src = state.src, start = state.pos;
  if (src.charCodeAt(start) !== 0x5B || src.charCodeAt(start + 1) !== 0x5B) return false;
  const end = src.indexOf("]]", start + 2);
  if (end < 0) return false;
  const inner = src.slice(start + 2, end);
  if (inner.indexOf("\n") >= 0) return false;
  if (!silent) {
    const innerClean = inner.replace(//g, "|");   // restore alias pipes hidden from the table parser
    const pipe = innerClean.indexOf("|");
    const target = (pipe >= 0 ? innerClean.slice(0, pipe) : innerClean).trim();
    const alias = (pipe >= 0 ? innerClean.slice(pipe + 1) : innerClean).trim();
    const resolved = isResolved(target);
    const open = state.push("link_open", "a", 1);
    open.attrSet("href", "#");
    open.attrSet("class", "wikilink" + (resolved ? "" : " unresolved"));
    open.attrSet("data-target", target);
    const txt = state.push("text", "", 0); txt.content = alias || target;
    state.push("link_close", "a", -1);
  }
  state.pos = end + 2;
  return true;
});

// ── File type → language (both panes) ───────────────────────────────────────
// A file with no extension counts as markdown: that's the boot state before Swift
// sends a path, and every vault note is markdown anyway.
const MD_EXTS = new Set(["", "md", "markdown", "mdown", "mkd", "mkdn"]);

function extOf(name) {
  const base = String(name || "").split("/").pop();
  const dot = base.lastIndexOf(".");
  return dot > 0 ? base.slice(dot + 1).toLowerCase() : "";
}

function isMarkdownFile(name) { return MD_EXTS.has(extOf(name)); }

// An .html file is a page: the preview renders it instead of showing its source.
const HTML_EXTS = new Set(["html", "htm"]);
function isHtmlFile(name) { return HTML_EXTS.has(extOf(name)); }

function markdownSupport() {
  // codeLanguages: languages — fenced ```python blocks get highlighted in the edit pane
  // too, not just in the preview (which goes through highlight.js).
  return markdown({ base: markdownLanguage, codeLanguages: languages, addKeymap: true });
}

// Swap the CodeMirror language for the open file. Non-markdown grammars load lazily
// (esbuild inlines the dynamic imports, so the module body only runs on demand).
async function applyLanguage(name) {
  if (!view) return;
  if (isMarkdownFile(name)) {
    view.dispatch({ effects: langC.reconfigure(markdownSupport()) });
    return;
  }
  const desc = LanguageDescription.matchFilename(languages, String(name).split("/").pop());
  let support = [];
  if (desc) { try { support = await desc.load(); } catch (e) { support = []; } }
  // The user may have switched notes while the grammar was loading.
  if (!view || currentFilename !== name) return;
  view.dispatch({ effects: langC.reconfigure(support) });
}

// Whole-file code preview — highlight.js is already bundled for fenced blocks, and its
// aliases cover the extensions directly (py→python, rs→rust, yml→yaml).
function renderCodePreview(text, ext) {
  let body;
  if (hljs.getLanguage(ext)) {
    try { body = hljs.highlight(text, { language: ext }).value; }
    catch (e) { body = escapeHtml(text); }
  } else {
    body = escapeHtml(text);
  }
  return `<pre class="code"><code class="hljs">${body}</code></pre>`;
}

// Rendered HTML lives in a sandboxed iframe. `allow-scripts` without `allow-same-origin`
// gives the document an opaque origin: scripts run (decks, dashboards, prototypes need
// them) but cannot reach this page, the Swift bridge, or file://. Content comes from
// agents and synced sources — the same trust boundary as markdown.
function renderHtmlPreview(el, text) {
  el.replaceChildren();
  const frame = document.createElement("iframe");
  frame.className = "html-preview";
  frame.setAttribute("sandbox", "allow-scripts");
  frame.srcdoc = text;
  el.appendChild(frame);
}

function renderPreview() {
  const el = document.getElementById("preview");
  const text = view ? view.state.doc.toString() : "";
  const html = isHtmlFile(currentFilename);
  el.classList.toggle("html", html);
  if (html) {
    renderHtmlPreview(el, text);
    return;
  }
  if (!isMarkdownFile(currentFilename)) {
    el.innerHTML = renderCodePreview(text, extOf(currentFilename));
    return;
  }
  el.innerHTML = md.render(protectWikilinkPipes(text));
  const nodes = el.querySelectorAll(".mermaid");
  if (nodes.length) {
    // "antiscript" strips <script>/JS event handlers from diagram labels (XSS-safe for
    // externally-synced notes) while still allowing <br/> in labels. Not "loose".
    mermaid.initialize({ startOnLoad: false, theme: dark ? "dark" : "neutral",
                         securityLevel: "antiscript",
                         fontFamily: '-apple-system, BlinkMacSystemFont, sans-serif' });
    mermaid.run({ nodes }).catch(() => {});
  }
}

// ── [[wikilink]] autocomplete (edit mode) ───────────────────────────────────
// Triggers on an open `[[` before the caret; offers vault note names, completing
// to `[[name]]` with the caret placed after the closing brackets.
function wikilinkSource(context) {
  const before = context.matchBefore(/\[\[[^\]\n]*$/);
  if (!before) return null;
  const query = before.text.slice(2).toLowerCase();
  if (!context.explicit && before.text === "[[" && !query) {
    // wait until at least the `[[` is there (it is) — allow empty query too
  }
  let names = noteNamesList;
  if (query) names = names.filter((n) => n.toLowerCase().includes(query));
  if (!names.length) return null;
  const options = names.slice(0, 50).map((n) => ({
    label: n,
    type: "text",
    apply: (view, completion, from, to) => {
      const insert = `${completion.label}]]`;
      view.dispatch({
        changes: { from, to, insert },
        selection: { anchor: from + insert.length },
      });
    },
  }));
  return { from: before.from + 2, options, filter: false };
}

// ── CodeMirror theme from the Svod palette ──────────────────────────────────
function makeTheme() {
  // A note reads best in a proportional font at reading measure; source code does not —
  // it needs a monospace face and the full pane width for alignment to mean anything.
  const code = !isMarkdownFile(currentFilename);
  return EditorView.theme({
    "&": { color: C.textPrimary, backgroundColor: C.editorSurface,
           fontSize: code ? "13px" : "15px", height: "100%" },
    ".cm-content": { fontFamily: code
                       ? 'ui-monospace, SFMono-Regular, "SF Mono", Menlo, monospace'
                       : '-apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif',
                     lineHeight: code ? "1.5" : "1.6", padding: "20px 0", caretColor: C.accent,
                     maxWidth: code ? "none" : "760px", margin: code ? "0" : "0 auto" },
    ".cm-scroller": { overflow: "auto", fontFamily: "inherit" },
    "&.cm-focused": { outline: "none" },
    ".cm-line": { padding: "0 28px" },
    ".cm-cursor, .cm-dropCursor": { borderLeftColor: C.accent },
    "&.cm-focused .cm-selectionBackground, .cm-selectionBackground, ::selection":
      { backgroundColor: C.selection },
    ".cm-activeLine": { backgroundColor: "transparent" },
    ".cm-gutters": { backgroundColor: C.editorSurface, color: C.textTertiary, border: "none" },
    ".cm-foldGutter": { color: C.textTertiary },
    // [[wikilink]] autocomplete popup
    ".cm-tooltip.cm-tooltip-autocomplete": {
      backgroundColor: C.surface, border: `1px solid ${C.borderSubtle}`,
      borderRadius: "8px", boxShadow: "0 8px 24px rgba(0,0,0,0.35)", overflow: "hidden",
    },
    ".cm-tooltip-autocomplete > ul": { fontFamily: "inherit", maxHeight: "260px" },
    ".cm-tooltip-autocomplete > ul > li": { padding: "4px 12px", color: C.textPrimary },
    ".cm-tooltip-autocomplete > ul > li[aria-selected]": {
      backgroundColor: C.selection, color: C.textPrimary,
    },
  }, { dark });
}

function makeHighlight() {
  const heading = { color: C.heading, fontWeight: "700" };
  return syntaxHighlighting(HighlightStyle.define([
    { tag: t.heading1, ...heading, fontSize: "1.6em" },
    { tag: t.heading2, ...heading, fontSize: "1.4em" },
    { tag: t.heading3, ...heading, fontSize: "1.2em" },
    { tag: [t.heading4, t.heading5, t.heading6], ...heading },
    { tag: t.strong, fontWeight: "700", color: C.textPrimary },
    { tag: t.emphasis, fontStyle: "italic", color: C.textPrimary },
    { tag: t.strikethrough, textDecoration: "line-through", color: C.textTertiary },
    { tag: [t.link, t.url], color: C.link, textDecoration: "underline" },
    { tag: t.monospace, color: C.code, fontFamily: "ui-monospace, SFMono-Regular, monospace" },
    { tag: [t.quote], color: C.textSecondary, fontStyle: "italic" },
    { tag: [t.list, t.processingInstruction], color: C.accent },
    { tag: [t.meta], color: C.textTertiary },
    // Code tags — without these a non-markdown file (or a fenced block) parses but every
    // token falls through unstyled, so Python looks like plain prose.
    { tag: [t.comment, t.lineComment, t.blockComment, t.docComment],
      color: C.textTertiary, fontStyle: "italic" },
    { tag: [t.keyword, t.controlKeyword, t.moduleKeyword, t.definitionKeyword,
            t.operatorKeyword, t.self], color: C.accent },
    { tag: [t.string, t.special(t.string), t.regexp], color: C.string },
    { tag: [t.number, t.bool, t.null, t.atom], color: C.linkUnresolved },
    { tag: [t.function(t.variableName), t.function(t.propertyName), t.labelName],
      color: C.link },
    { tag: [t.typeName, t.className, t.namespace, t.tagName, t.standard(t.variableName)],
      color: C.link },
    { tag: [t.propertyName, t.attributeName, t.variableName, t.definition(t.variableName)],
      color: C.textPrimary },
    { tag: [t.operator, t.punctuation, t.separator, t.bracket, t.paren, t.brace, t.squareBracket],
      color: C.textSecondary },
    { tag: t.invalid, color: C.linkUnresolved },
  ]));
}

// ── Editor setup ────────────────────────────────────────────────────────────
// ── Focus mode — dim every line except the caret's (toggled from Swift) ──────
let focusMode = false;
const focusDim = Decoration.line({ class: "cm-focus-dim" });
const focusPlugin = ViewPlugin.fromClass(class {
  constructor(view) { this.decorations = this.build(view); }
  update(u) { this.decorations = this.build(u.view); }
  build(view) {
    if (!focusMode) return Decoration.none;
    const activeLine = view.state.doc.lineAt(view.state.selection.main.head).number;
    const deco = [];
    for (const { from, to } of view.visibleRanges) {
      let pos = from;
      while (pos <= to) {
        const line = view.state.doc.lineAt(pos);
        if (line.number !== activeLine) deco.push(focusDim.range(line.from));
        pos = line.to + 1;
      }
    }
    return Decoration.set(deco);
  }
}, { decorations: (v) => v.decorations });

function buildState(doc) {
  return EditorState.create({
    doc,
    extensions: [
      history(),
      drawSelection(),
      indentOnInput(),
      bracketMatching(),
      highlightSelectionMatches(),
      foldGutter(),
      EditorView.lineWrapping,
      langC.of(markdownSupport()),
      autocompletion({ override: [wikilinkSource], activateOnTyping: true, icons: false }),
      focusPlugin,
      hlC.of(makeHighlight()),
      themeC.of(makeTheme()),
      keymap.of([...completionKeymap, ...defaultKeymap, ...historyKeymap, ...searchKeymap, ...foldKeymap, indentWithTab]),
      EditorView.updateListener.of((u) => {
        if (u.docChanged && !applyingExternal) scheduleChange();
      }),
    ],
  });
}

let changeTimer = null;
function scheduleChange() {
  clearTimeout(changeTimer);
  changeTimer = setTimeout(() => {
    post({ type: "change", text: view.state.doc.toString() });
  }, 150);
}

let previewOn = false;

function setMode(mode) {
  const editEl = document.getElementById("editor");
  const prevEl = document.getElementById("preview");
  previewOn = mode === "preview";
  if (mode === "preview") {
    renderPreview();
    editEl.style.display = "none";
    prevEl.style.display = "block";
  } else {
    prevEl.style.display = "none";
    editEl.style.display = "block";
    if (view) view.focus();
  }
}

// Preview click delegation → wikilink / external link out to Swift.
function installPreviewClicks() {
  document.getElementById("preview").addEventListener("click", (e) => {
    const a = e.target.closest("a");
    if (!a) return;
    e.preventDefault();
    if (a.classList.contains("wikilink")) post({ type: "openLink", target: a.dataset.target });
    else if (a.href) post({ type: "openExternal", href: a.href });
  });
}

// ── Public bridge (called from Swift via evaluateJavaScript) ────────────────
window.SvodEditor = {
  setContent(text) {
    if (!view) return;
    applyingExternal = true;
    view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: text } });
    applyingExternal = false;
    // Swift only calls setMode when the mode itself changes, so content arriving after
    // the pane is already in preview (a note that finishes loading after boot) would
    // otherwise leave the last-rendered — or empty — preview on screen.
    if (previewOn) renderPreview();
  },
  getContent() { return view ? view.state.doc.toString() : ""; },
  setMode,
  // Swift pushes the open file's path; both panes key off its extension.
  setLanguage(path) {
    const name = String(path || "");
    if (name === currentFilename) return;
    const wasCode = !isMarkdownFile(currentFilename);
    currentFilename = name;
    applyLanguage(name);
    // Prose ⇄ code changes the font/measure, so the theme has to follow the file type.
    if (view && wasCode !== !isMarkdownFile(name)) {
      view.dispatch({ effects: themeC.reconfigure(makeTheme()) });
    }
    if (previewOn) renderPreview();
  },
  setFocusMode(on) { focusMode = !!on; if (view) view.dispatch({}); },
  setNoteNames(arr) {
    noteNamesList = (arr || []).map((n) => String(n).replace(/\.md$/i, "").trim()).filter(Boolean);
    noteNames = new Set(noteNamesList.map((n) => n.toLowerCase()));
  },
  configure(opts) {
    if (opts && opts.colors) C = Object.assign(C, opts.colors);
    if (opts && typeof opts.dark === "boolean") dark = opts.dark;
    if (view) view.dispatch({ effects: [themeC.reconfigure(makeTheme()), hlC.reconfigure(makeHighlight())] });
    document.body.style.background = C.editorSurface;
    document.body.classList.toggle("dark", dark);
  },
  focus() { if (view) view.focus(); },
};

// ── Boot ────────────────────────────────────────────────────────────────────
function boot() {
  view = new EditorView({ state: buildState(""), parent: document.getElementById("editor") });
  installPreviewClicks();
  document.body.style.background = C.editorSurface;
  document.body.classList.toggle("dark", dark);
  post({ type: "ready" });
}

if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", boot);
else boot();
