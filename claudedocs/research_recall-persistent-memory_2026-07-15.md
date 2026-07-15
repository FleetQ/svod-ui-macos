# Research: "recall" (Viget) persistent memory за Claude Code — какво да взаимстваме

**Дата:** 2026-07-15
**Източник:** https://www.viget.com/articles/giving-claude-code-a-persistent-memory (Max Myers, Viget) · repo: https://github.com/maxdmyers/recall
**Обхват:** сравнение спрямо съществуващия ни stack (Svod engine + Serena memories + auto-memory MEMORY.md + svod-foundry + Harbormaster)
**Confidence:** висок за механиката на recall (описана директно в статията); среден за детайли по имплементацията (repo не е прочетен ред по ред)

---

## Executive summary (БГ)

`recall` е **лека** self-improving памет за Claude Code, изградена само от съществуващи примитиви: Claude Code hooks (`Stop` + `SessionStart`), bash + jq, един headless `claude -p` за дистилация, `launchd` за график и **папка от markdown** като vault. Без сървър, без БД, git-синхронизиран, Obsidian-съвместим.

Ключовият извод: **нашата инфраструктура за съхранение вече е по-мощна от recall** (Svod engine = версиониран, атрибутиран, graph-linked note store с embeddings; Serena; foundry). Затова **не бива да взаимстваме storage-а — той е слабата им страна спрямо нас.** Взаимстваме **процеса**, който при нас го няма:

1. **Автоматичен, безплатен capture** (`Stop` hook дъмпва суровата сесия, БЕЗ LLM) — при нас записът в паметта е ръчен/LLM-in-the-loop и затова е загубващ: ако забравя да запиша или сесията умре, знанието изчезва.
2. **Нощна batch дистилация с евтин модел** извън интерактивната сесия — при нас дистилираме inline със скъпия основен модел, което гори контекст и пари.
3. **Inbox за предложения (skills/tools) от cross-session pattern mining** — при нас foundry синтезира инструмент само когато аз *в момента* се сблъскам с нуждата; нищо не наблюдава повтарящи се модели през сесии.
4. **Правило за стесняване на обхвата**: project-local до появата в 2+ проекта → чак тогава global.

Препоръка: **не внасяме recall като проект.** Пресъздаваме неговия 4-степенен loop върху НАШИТЕ примитиви (Svod `messy/` + `remember` + promote, `schedule`/CronCreate за нощния job, съществуващия SessionStart hook за retrieve). Виж "Recommendations".

---

## Как работи recall (4-степенен loop)

| Стъпка | Trigger | Прави | Цена |
|---|---|---|---|
| **1. Capture** | `Stop` hook (край на сесия) | Дъмпва сесията в private vault. Чист shell, **без LLM call**. "Grab what you did and stay out of the way." | Безплатно |
| **2. Distill** | Нощен `launchd` job | Чете недистилираните сесии за деня, стрипва tool calls + шум, компресира в durable knowledge notes. Заключен на `sonnet-4-6`. ~**27x компресия**. | ~$0.85/нощ (~$20/мес, по-евтино с Haiku) |
| **3. Retrieve** | `SessionStart` hook | Инжектира релевантния **knowledge index** като context; Claude чете отделните notes on-demand. | Евтино (само индекс) |
| **4. Surface** | Дистилаторът при повтарящ се cross-session модел | Пише **skill proposal** в `inbox/proposals.md` със `scope: project\|global` + confidence rating. Нищо не се създава автоматично. | Част от distill |

**Feedback loop:** написаното в стъпка 2 се чете в стъпка 3 → всяка сесия и захранва, и се възползва от vault-а.

### Дизайн-принципи (това е ценното)
- **Capture is free by design** — hot path-ът никога не вика LLM; capture е декуплиран от distill.
- **Smart distillation** — стрипва tool calls, заключен евтин модел; качество без цена.
- **Suggestions over automation** — proposals в inbox; човекът решава (safety + контрол над token разходи).
- **Knowledge scoped as narrowly as possible** — модел в 1 проект стои local; поява в 2+ проекта → предлага се като global. Държи global-а lean.
- **Portable** — git-синхронизиран markdown vault, нула сървъри/демони.

### Резултати за 6 седмици (self-reported)
80+ сесии / 6 проекта · 70+ knowledge notes · ~27x компресия · ~$0.85/нощ · dashboard, ъпдейтван след всеки distill.

---

## Съпоставка спрямо нашия stack

| recall концепция | Имаме ли го? | При нас |
|---|---|---|
| Markdown vault | ✅ **По-силно** | Svod engine: версиониран, атрибутиран, graph-linked, embeddings, revisions, optimistic concurrency |
| SessionStart инжектира индекс | ✅ Имаме | Auto-memory `MEMORY.md` + Serena auto-load hook инжектира индекса на старт; on-demand четене на отделни memories |
| Drafts → curated lifecycle | ✅ Имаме | `messy/` quarantine + `promote()`; `provisional → active` graduation за fact/policy |
| Tool/skill генериране | ⚠️ Частично | svod-foundry синтезира **on-demand** (когато аз ударя нуждата), НЕ от cross-session mining |
| Cross-project scope | ⚠️ Частично | Serena `global/` vs project memories; Harbormaster дава cross-project reach — но **няма авто-promotion** правило |
| **Автоматичен capture (Stop hook, no-LLM)** | ❌ **Липсва** | Записът е ръчен/LLM-in-loop → загубващ |
| **Нощна batch дистилация (евтин модел, off-session)** | ❌ **Липсва** | Дистилираме inline със скъпия модел, в интерактивния контекст |
| **Pattern-surfacing inbox (recurring → proposal)** | ❌ **Липсва** | Нищо не наблюдава повтарящи се модели през сесии |
| **Правило project→global (2+ прояви)** | ❌ **Липсва** | Ръчна преценка |
| Dashboard / метрики за паметта | ❌ Липсва | — |

**Извод:** покриваме storage + retrieve отлично. Дупката ни е целият **write-side автоматизъм**: capture, off-line distill, и pattern-surfacing.

---

## Взаимстваеми идеи (класирани)

### 1. Автоматичен, безплатен capture hook — **HIGH value, LOW effort** ⭐
Проблемът, който решава: днес глобалната инструкция "After completing any non-trivial task, save learnings" зависи от това аз да се сетя и от това сесията да оцелее. Това е загубващо.
Борба: `Stop` hook (чист shell, без LLM) дъмпва транскрипта на сесията в `messy/sessions/<ts>-<project>.md` в Svod (или на диск за нощния job). Нула цена, нула намеса в сесията. Дистилацията идва по-късно и отделно.

### 2. Нощна batch дистилация с евтин модел — **HIGH value, MEDIUM effort** ⭐
Проблемът: дистилираме inline със скъпия основен модел → гори интерактивен контекст и пари.
Борба: scheduled job (нашият `schedule` skill / CronCreate, или `launchd` като тях) нощем пуска `claude -p` с **Haiku 4.5** върху събраните `messy/sessions/*`, стрипва tool calls, и записва durable памет чрез `mcp__svod__remember` (typed: policy/fact/preference/episode) + `promote()` от messy/. Съответства 1:1 на нашия lifecycle. Заключването на евтин модел + стрипване на tool calls е директно копируемо.

### 3. Cross-session pattern → tool/skill proposal inbox — **MEDIUM value, MEDIUM effort**
Проблемът: foundry реагира само на моментна нужда; повтарящите се модели през сесии не се улавят.
Борба: нощният distiller, освен памет, дописва в Svod note `inbox/proposals` кандидати за foundry tool или skill със `scope` + confidence. Аз ги ревюирам ръчно (suggestions-over-automation — пази и контрол, и token разходи). Захранва съществуващия foundry pipeline вместо да го заобикаля.

### 4. Правило за стесняване на обхвата (project → global при 2+ прояви) — **MEDIUM value, LOW effort**
Борба: distiller-ът маркира знание като project-local по подразбиране; при поява в 2+ проекта (Harbormaster/cross-project index го прави откриваемо) предлага промоция към Serena `global/`. Държи global-а lean — точно проблема, за който имаме `global/feedback-*` memories.

### 5. Метрики/dashboard за паметта — **LOW value, LOW effort**
Компресия, брой notes, разход/нощ. Nice-to-have; не приоритет.

### Съзнателно НЕ взаимстваме
- **Storage-а/vault формата** — Svod engine вече го превъзхожда (версии, graph, embeddings, атрибуция). Внасянето на плоски markdown би било регрес.
- **launchd като механизъм** — имаме `schedule`/CronCreate cloud agents; по-преносимо от launchd (recall сам признава "macOS only for the moment").
- **Пълния recall проект** — дублира substrate-а ни; вземаме процеса, не кода.

---

## Recommendations (за човешко решение — без имплементация тук)

**Предложение: пресъздай recall loop-а върху НАШИТЕ примитиви, минимална версия първо.**

- **Фаза 1 (бърза печалба):** Stop-hook capture → `messy/sessions/` + нощен `schedule` job с Haiku, който `remember()`-ва и promote-ва. Това затваря най-голямата ни дупка (загубващ ръчен запис) с малко код. Идеи #1 + #2.
- **Фаза 2:** proposal inbox към foundry + правилото project→global. Идеи #3 + #4.
- **Фаза 3 (опц.):** dashboard. Идея #5.

**Отворени въпроси за теб:**
1. Capture: сурови транскрипти в Svod `messy/` (версионирано, но раздува vault-а), или на диск извън vault-а и само дистилатите влизат в Svod? recall държи суровото в private vault отделно от durable notes.
2. Distill scheduling: нашият `schedule`/CronCreate cloud agent (преносимо) vs локален `launchd` (нула cloud, като тях)?
3. Обхват: само този проект (svod-ui-macos), или глобално през всички `~/htdocs/*` (тогава Harbormaster + правилото за scope стават релевантни)?

**Следваща стъпка:** ако одобриш посоката → `/sc:design` за архитектурата на capture→distill pipeline-а върху Svod/schedule примитивите. Този доклад не имплементира нищо.

---

## Sources
- Viget, Max Myers — "Giving Claude Code A Persistent Memory", 2026-07-15 (primary; механика на loop-а, дизайн-принципи, метрики).
- github.com/maxdmyers/recall (споменат; не прочетен ред по ред — оттам среден confidence по детайли).
- Собствени Serena memories: `svod-ui-architecture`, `svod-claude-mem-borrowed-ideas`, auto-memory `MEMORY.md` (текущо състояние на нашия stack).
