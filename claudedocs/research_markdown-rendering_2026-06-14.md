# Research: Готова библиотека за пълно markdown рендиране в Svod

**Дата:** 2026-06-14
**Въпрос:** Има доста проблеми с рендирането на markdown-а и не е ефективно да ги отстраняваме един по един. Няма ли готова библиотека, която да адресира всичко?
**Тип:** Архитектурно проучване (research only — без имплементация)
**Увереност:** Висока (първоизточници: README-та, MarkEdit wiki, GitHub API)

---

## Executive summary

Краткият отговор е **„и да, и не"** — и разликата е изцяло в това дали говорим за *показване* или за *редактиране* на markdown:

- **За само-показване (read-only render):** ДА, има зрели библиотеки, които покриват почти всичко (GFM таблици, task lists, code, images), а mermaid се добавя с custom code-block view. → **MarkdownUI / Textual**.
- **За live single-surface редактор (какъвто е Svod — пишеш markdown и го виждаш стилизиран на място):** НЕ съществува native Swift библиотека, която да „покрива всичко". Всеки сериозен редактор (MarkEdit, Obsidian, Simple MD) или (а) ползва **web редактор (CodeMirror 6 / ProseMirror) в WKWebView**, или (б) рендира в отделен preview и показва таблици/mermaid в **popover/страничен** изглед.

**Коренната причина за повтарящите се бъгове в Svod не е „липса на библиотека", а че парсингът е ръчен (regex).** Най-ефективната стъпка не е да сменим целия редактор, а да заменим regex highlighter-а с **истински AST парсер (apple/swift-markdown, cmark-gfm)**, който дава source ranges → мапваш ги към `NSRange` и стилизираш от коректно дърво. Това спира бъговете при източника, без да хвърля вече построеното (table layout manager, mermaid).

---

## Картата на наличните решения (2026)

### 1. Read-only рендери (native SwiftUI) — „покриват всичко", но НЕ редактират

| Библиотека | Статус | Покритие | За редактиране? |
|---|---|---|---|
| **MarkdownUI** (`gonzalezreal/swift-markdown-ui`) | ⚠️ Maintenance mode (3.9k★, last push 2025-12) | GFM: таблици, task lists, code, blockquotes, images, thematic breaks; пълно theming; custom code-block style | ❌ само показване |
| **Textual** (`gonzalezreal/textual`) | ✅ Активен наследник (724★, създаден 2025-12, push 2026-06) | „SwiftUI text rendering engine, който поддържа Markdown"; пази `Text` pipeline-а на SwiftUI | ❌ само показване, млад (~6 мес.) |

- **macOS изисквания:** MarkdownUI = macOS 12+ (таблици/multi-image = 13+). Svod таргети macOS 14 → ОК.
- **Mermaid:** и двете позволяват custom code-block рендер — хващаш `language == "mermaid"` и връщаш SwiftUI view, обвиващ WKWebView (точно подходът, който вече имплементирахме нативно). Източниците потвърждават техниката.
- **Защо НЕ решават проблема на Svod:** Svod е edit-in-place. Тези са `Markdown(text)` view-та за четене. Ползата им е реална само за read-only повърхнини (preview, inspector, history/diff render).

### 2. NSTextView highlighter-и (същият подход като сегашния на Svod)

`Marklight`, `HighlightedTextEditor` (kyle-n), `Sourceful` (twostraws), `SwiftDown` (qeude), `SwiftUIMarkdownEditor`.

- Всичките са **regex/ръчно стилизиране върху NSTextView/UITextView** — точно архитектурата, която Svod вече има. Преминаване към тях **няма да премахне** класа бъгове, защото споделят корена (regex, не AST). Могат да послужат само като референция за идиоми.

### 3. Истински парсер за под съществуващия редактор (ключово за Svod)

- **`swiftlang/swift-markdown`** (Apple) — Swift пакет над **cmark-gfm**; immutable/thread-safe AST. **Дава source ranges за всеки node** → мапваш AST → `NSRange` и стилизираш коректно (вложен emphasis, edge cases, GFM таблици, code fences — всичко, което regex бърка). Това е „един източник на истина" вместо ~12 regex паса.
- **`swiftlang/swift-cmark`** (gfm branch) — самата C библиотека отдолу.
- **Code syntax highlighting** (за вътре в code блоковете):
  - **Splash** (JohnSundell) — native Swift, но фокусиран върху Swift синтаксис (ограничен за други езици).
  - **Highlightr** (highlight.js през JSContext) — ~190 езика, по-широко покритие, по-тежък.

### 4. Web редактор в WKWebView — „наистина покрива всичко", но сменя двигателя

- **MarkEdit** (4.95k★, активен, Swift) — CodeMirror 6 в native WebView. 100% GFM, отваря 10MB файлове плавно, 4MB app, multi-caret, native chrome. За таблици/LaTeX/**mermaid** ползва **popover preview**.
- **Milkdown** (ProseMirror) / **Simple MD** / **Human Markdown** — истински WYSIWYG markdown с плъгини за таблици, code highlight и **mermaid** „наготово".
- Цена: редакторското ядро вече не е AppKit; обвиваш го в WKWebView и bridge-ваш към engine-а.

---

## Решаващото свидетелство: защо MarkEdit избра web редактор

От „Why MarkEdit" wiki (екип с 10+ г. опит на Apple платформи, познават TextKit 1 и 2):

> „We built the core editor based on CodeMirror 6 … we know text editing on macOS quite well, including TextKit 1 and TextKit 2, but still chose a web editor. A simple fact is that **TextKit is not better than contentEditable**, the community doesn't even have one single editor that can compete with CodeMirror or Monaco. **Implementing the same behavior using TextKit is desperately hard** … we are tired of exploring the darkness inside TextKit."

И за preview-то (вместо inline WYSIWYG):

> „there're several situations we do need to preview, such as tables, embedded LaTeX formulas, or **Mermaid diagrams, we have built popover previews** for that."

Изводът: дори експерти не правят пълноценен WYSIWYG markdown върху чист TextKit — затова Svod ще удря edge cases безкрайно, ако остане на ръчен regex върху NSTextView. Това е системно ограничение, не липса на усилие.

---

## Трите реалистични пътя за Svod

### Път A — Истински парсер под съществуващия редактор ⭐ препоръчан (краткосрочно)
Замени regex highlighter-а с **apple/swift-markdown**; стилизирай от AST чрез source ranges → `NSRange`. Добави Highlightr/Splash за код. Запази table layout manager + mermaid (вече готови).
- **Плюс:** маха корена на повтарящите се бъгове; пази single-surface live дизайна; малък риск; не хвърля свършена работа.
- **Минус:** ти все още „рисуваш" таблици/mermaid (но това вече е направено). Не е магически „всичко наготово".
- **Усилие:** средно. **Риск:** нисък.

### Път B — Render библиотека + dual-mode (raw ↔ rendered)
MarkdownUI/Textual за показване (+ custom mermaid block), raw NSTextView за редакция, toggle/live-preview per блок.
- **Плюс:** най-добро покритие на рендиране с най-малко код за рендиране.
- **Минус:** reveal/sync слоят (raw↔rendered на фокусирания блок) е точно частта, която **никоя библиотека не дава** — пак го пишеш сам, и губиш чистия single-surface усет.
- **Усилие:** средно-голямо. **Риск:** среден. → най-слаб fit.

### Път C — Web редактор (CodeMirror 6 / Milkdown) в WKWebView
Подходът на MarkEdit/Obsidian. Истински „покрива всичко": multi-caret, code folding, 100% GFM, mermaid, огромни файлове, зряла екосистема.
- **Плюс:** най-голям behavioral скок; добре утъпкан път; MarkEdit доказва, че пак е „native-feeling" (4MB, native chrome).
- **Минус:** редакторската повърхнина вече не е native AppKit; пренаписване; противоречи на „zero-web, native-first" инстинкта.
- **Усилие:** голямо. **Риск:** среден (добре документиран). Референция: MarkEdit е open-source.

---

## Препоръка

1. **Сега:** Път A — приеми **apple/swift-markdown** като парсер, който храни съществуващия highlighter; + **Highlightr** за многоезичен code highlight. Това адресира директно оплакването („не е ефективно един по един") — премахва класа бъгове при източника, без рискован rewrite.
2. **Запази** mermaid + таблиците както са — нашият custom layout-manager рендер е функционално еквивалент на MarkEdit-овия „inline/popover preview" и е добър.
3. **За read-only повърхнини** (history/diff preview, inspector, бъдещ export) — обмисли **Textual/MarkdownUI** вместо ръчно рисуване.
4. **Преразгледай Път C само ако** по-късно искаш истински WYSIWYG (multi-caret, code folding, безупречен GFM) и си готов да пренапишеш редактора — тогава MarkEdit е референтната имплементация.

Решението е на потребителя. Следваща стъпка по избор: `/sc:design` за архитектура на Път A, или директна имплементация при потвърждение.

---

## Sources
- MarkEdit — Why MarkEdit (CodeMirror vs TextKit, popover preview за mermaid): https://github.com/MarkEdit-app/MarkEdit/wiki/Why-MarkEdit
- swift-markdown-ui (MarkdownUI) — maintenance mode + custom code block: https://github.com/gonzalezreal/swift-markdown-ui
- Textual (наследник): https://github.com/gonzalezreal/textual
- Better Markdown Rendering in SwiftUI (gonzalezreal): https://gonzalezreal.github.io/2023/02/18/better-markdown-rendering-in-swiftui.html
- SwiftUI Markdown + Mermaid през WKWebView (техника): https://medium.com/@dorangao/swiftui-markdown-previews-should-render-mermaid-not-dump-raw-code-d1aeb0c9b6b0
- apple/swift-markdown (cmark-gfm AST, source ranges): https://github.com/swiftlang/swift-markdown
- swift-cmark (gfm): https://github.com/swiftlang/swift-cmark
- Splash (Swift syntax highlighting): https://github.com/JohnSundell/Splash
- Milkdown (ProseMirror WYSIWYG): https://github.com/Milkdown/milkdown
- MarkupEditor (SwiftUI WYSIWYG, HTML-базиран): https://swiftpackageindex.com/stevengharris/MarkupEditor
- Review of Markdown parsers for Swift (Loopwerk): https://www.loopwerk.io/articles/2021/review-markdown-parsers/
