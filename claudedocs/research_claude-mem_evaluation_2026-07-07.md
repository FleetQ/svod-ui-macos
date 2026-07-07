# Research: claude-mem — може ли да го ползваме за Svod engine и/или UI?

**Дата:** 2026-07-07
**Обект:** [thedotmack/claude-mem](https://github.com/thedotmack/claude-mem) (v13.10.2, Apache-2.0)
**Въпрос:** Бихме ли могли да го използваме за Svod engine-а и/или за UI-а?
**Confidence:** High за архитектурата (README + package.json прочетени директно); Medium за вътрешни детайли (schema, MCP tool имена — линкнати към docs.claude-mem.ai, не към surface-ната в repo-то).

---

## Executive Summary

**Кратко: не като компонент за вграждане — claude-mem е конкурент/двойник на самия Svod, не градивен блок за него.**

claude-mem е персистентна памет за Claude Code, изградена от **същите концептуални части като Svod**: локална SQLite база + векторно търсене + MCP tools + локален HTTP worker с web viewer + lifecycle hooks. Двата проекта решават *един и същ проблем* (durable, searchable памет през сесии), но с различни залози:

- **claude-mem** = **автоматична компресия на транскрипти** (Claude сам captures observations през hook-ове; нулева ръчна намеса). TypeScript/Node/Bun + Python (uv/Chroma).
- **Svod** = **умишлено авторирана, версионирана, attributable graph памет** (git-backed commits, wikilinks, optimistic concurrency, `remember`/`promote` lifecycle). JVM engine + нативен SwiftUI клиент.

Затова припокриването е **на ниво продукт**, не на ниво library. Няма чист "модул" от claude-mem, който да се закачи в Svod engine-а без да носи целия си Bun+Python+SQLite+Chroma стек — което дублира това, което engine-ът вече прави.

**Стойността от него е като референция/източник на идеи, не като зависимост.** Виж "Какво заслужава да откраднем" по-долу.

---

## Какво представлява claude-mem (архитектура)

Шест части, всичките локални:

| # | Компонент | Роля |
|---|-----------|------|
| 1 | **5 Lifecycle Hooks** (SessionStart, UserPromptSubmit, PostToolUse, Stop, SessionEnd — 6 скрипта) | Автоматично прихващат tool-usage observations и генерират семантични summaries |
| 2 | **Smart Install** (pre-hook, cached dependency checker) | Auto-инсталира липсващи зависимости |
| 3 | **Worker Service** (локален HTTP API, управляван от Bun) | Search endpoints + **web viewer UI** (real-time memory stream на URL, принтнат при startup) |
| 4 | **SQLite база** | sessions, observations, summaries + **FTS5** keyword търсене |
| 5 | **mem-search Skill** | Natural-language заявки с *progressive disclosure* (layered retrieval + видима token cost) |
| 6 | **Chroma Vector DB** (Python) | Hybrid semantic + keyword търсене |

**MCP surface:** 4 MCP tools в **3-layer workflow** (token-efficient progressive disclosure — layer 1 евтин overview, дълбаене надолу само при нужда).

**Runtime зависимости:** Node ≥20, **Bun** (auto-installed), **uv** (Python pkg manager, auto-installed за Chroma), SQLite3 (bundled). Built with Claude Agent SDK. Multi-mode през `CLAUDE_MEM_MODE`.

**Privacy:** `<private>` тагове изключват съдържание от съхранение.

---

## Пряко сравнение със Svod

| Измерение | claude-mem | Svod |
|---|---|---|
| **Модел на паметта** | Авто-компресия на транскрипти (observations) | Умишлено авторирани markdown notes на `path` |
| **Версии/audit** | sessions/summaries в SQLite | **git commit на всеки write**, `history`/`diff`/`get_revision`, optimistic concurrency (`expectedRevision`) |
| **Граф** | Chroma vectors + FTS5 | Wikilinks + `graph_query` (1-hop backlinks/outlinks) |
| **Търсене** | Hybrid semantic+keyword (Chroma+FTS5) | Hybrid keyword/semantic (`search`, `context_pack`); embedder bge-m3 |
| **Lifecycle** | Auto capture/compress | `remember`/`promote`, provisional→active, `.trash/` soft-delete |
| **Storage** | SQLite + Chroma, per-`CLAUDE_MEM_MODE` | Git vault(и), multivault, sync през git-as-bus |
| **Backend runtime** | TS/Node + **Bun** + **Python** | JVM engine (:7619 launchd) |
| **UI** | Web viewer (worker URL, browser) | **Нативен SwiftUI macOS** клиент (loopback :7517) |
| **MCP** | 4 tools, 3-layer | Богат `mcp__svod__*` surface (read/write/graph/history) |
| **Фокус** | Zero-effort continuity за Claude Code | Auditable, attributable, cross-session knowledge substrate + Tool Foundry recall |

**Извод:** това не са допълващи се системи, а **два дизайна на едно и също нещо**. Svod вече покрива всяко ядро на claude-mem — и на места (версиониране, attribution, git-backed audit) е по-строг.

---

## Оценка по target

### За engine-а — ❌ не препоръчвам вграждане

1. **Дублира съществуваща функционалност.** Svod engine вече прави SQLite/векторно търсене, MCP surface и durable storage. claude-mem не добавя липсваща способност — предлага паралелна.
2. **Runtime конфликт.** claude-mem влачи Bun + Python(uv)+Chroma. Svod engine е JVM. Вкарването значи трети и четвърти рънтайм в стека само за памет — против чистия HTTP/JSON модел на Svod.
3. **Различна философия на данните.** claude-mem компресира транскрипти автоматично; Svod умишлено версионира авторирани notes. Наливането на auto-observations в git-backed vault-а ще замърси curated паметта и ще взриви commit шума.
4. **Няма извличаем "модул".** Стойността е в интеграцията hooks↔worker↔Chroma↔skill — не в отделна library за import.

### За UI-а — ❌ не като компонент, но ⚠️ полезно като референция

1. **Web viewer vs нативен клиент.** claude-mem web viewer е browser-базиран HTTP UI; Svod UI е нативен SwiftUI (dark-first, design-token система). Различни технологии — нищо за директно преизползване.
2. **Референтна стойност.** "Real-time memory stream", "progressive disclosure с видима token cost", и citation-по-observation-ID са добри UX идеи, които може да реплицираме нативно.

---

## Какво заслужава да „откраднем" (idea-level, не код)

1. **Progressive disclosure с видима token cost** — 3-layer MCP workflow, който показва колко контекст „струва" всяко разкриване. Директно приложимо към Svod `context_pack` и към inspector-а на UI-а.
2. **`<private>` тагове** — прост, елегантен opt-out на чувствително съдържание от индексиране. Лесно за пренасяне в Svod write-path.
3. **Lifecycle-hook auto-capture (опционално)** — Svod е умишлено ръчен; *опционален* auto-observation режим (ясно отделен от curated vault-а, напр. в `messy/`) би хванал контекст, който иначе се губи. Design trade-off, не задача.
4. **Real-time memory-stream viewer** — activity feed в нативния UI, показващ входящи observations на живо (Svod UI вече има Activity feature — може да се обогати).

---

## Препоръка

**Не интегрирай claude-mem в engine-а или в UI-а.** Той е архитектурен двойник на Svod с по-тежък polyglot рънтайм (Bun+Python+Chroma) и по-хлабав модел на данните (auto-compress vs versioned-authored). Вграждането добавя дублиране и зависимости без нова способност.

**Използвай го за друго:**
- **Benchmark** — стартирай го странично, за да сравниш качеството на retrieval-а (Chroma hybrid) спрямо Svod bge-m3 keyword+semantic; ако тяхното е забележимо по-добро, това е сигнал за embedder/ranking работа в Svod.
- **UX mining** — вземи progressive-disclosure + token-cost + `<private>` идеите в Svod roadmap-а.

---

## Отворени въпроси (ако решим да копаем по-дълбоко)

- Точните имена/сигнатури на 4-те MCP tools и exact SQLite schema — линкнати към `docs.claude-mem.ai`, не surface-нати в repo README-то. Изисква fetch на docs сайта или клониране на repo-то.
- Как точно Chroma hybrid ranking bие или губи спрямо bge-m3 на Svod — само empirичен бенчмарк отговаря.

---

## Sources

- `github.com/thedotmack/claude-mem` — README.md (прочетен директно, 115 секции)
- `raw.githubusercontent.com/.../package.json` — v13.10.2, deps note (bundler externalization)
- `api.github.com/repos/thedotmack/claude-mem` — repo meta
- Svod UI architecture (Serena memory `svod-ui-architecture`) + global CLAUDE.md Svod/Foundry секции
- Docs (не fetch-нати): `docs.claude-mem.ai/architecture/*`
