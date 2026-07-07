# Brainstorm: 4-те идеи от claude-mem, приложени към Svod — Requirements Discovery

**Дата:** 2026-07-07
**Режим:** `/sc:brainstorm` — requirements discovery ONLY (без архитектура, без код, без schema)
**Вход:** докладът `research_claude-mem_evaluation_2026-07-07.md`
**Grounding:** прочетени реални точки в кода —
`svod/engine .../mcp/SvodTools.kt` (`contextPack(access, SearchQuery, tokenBudget, enumerate)`),
`.../mcp/SvodMcpServer.kt` (tools: read/write/search/context_pack/remember/promote),
UI `Features/Activity/{ActivityFeedView,RelativeTime}.swift` + `App/ActivityModel.swift`,
UI `Features/Inspector/InspectorView.swift` + `App/InspectorModel.swift`.

---

## Ключово откритие, което пренарежда всичко

Две от четирите идеи **вече са полу-налични** в Svod, което мени изцяло тяхната цена:

1. **Token budget вече се смята в engine-а.** `contextPack` приема `tokenBudget`, greedy-пълни до него, dedup-ва и цитира. „Видимата token cost" не е нова машина — а **изнасяне на число, което вече е изчислено**. → най-евтината идея.
2. **Real-time memory stream вече съществува.** UI-ът има `ActivityFeedView`/`ActivityModel`, който консумира WS `/api/v1/events` (`agent.activity`/`commit.created`, dedupe по `data.commit`). claude-mem web viewer е browser; Svod е нативен и вече по-напред. → идея 4 е **enrichment, не нова способност**.

Обратно — `<private>` и auto-capture са **истински нови** и двете докосват чувствителни пътища (index/embeddings/recall, git история, „deliberate" философията).

**Приоритетна карта (по цена↑ / риск↑):**

| Идея | Цена | Риск | Тип |
|---|---|---|---|
| 1. Token cost visibility | ниска | нисък | expose съществуващо |
| 4. Memory-stream enrichment | средна | нисък | UI enrichment |
| 2. `<private>` | средно-висока | **висок (security)** | нова способност |
| 3. Auto-capture | висока | **висок (философия+LLM)** | нова подсистема |

Естествено секвениране: **1 → 4 → 2 → 3** (2 е guardrail-предпоставка за 3 — не бива да auto-capture-ваш тайни).

---

## Идея 1 — Progressive disclosure с видима token cost

### Проблем
Агент, който вика `context_pack`/`search`, получава блок без евтин преглед „какво има и колко тежи" преди да похарчи budget. Няма layer-0 манифест. UI Inspector-ът показва recall-нат контекст, но (вероятно) не и колко от context window-а изяжда.

### Какво взаимстваме
claude-mem 3-layer workflow: **layer 0** евтин overview (заглавия + token cost + citation ID, без тела) → **layer 1/2** дълбаене само при нужда, с видима цена на всяка стъпка.

### Functional requirements
- FR1.1 — `context_pack`/`search` да връщат **per-block token estimate** + **cumulative** за пакета.
- FR1.2 — режим „манифест" (layer 0): заглавия + path/citation ID + token cost, **без** тела; по образец на съществуващия `enumerate: true` флаг.
- FR1.3 — извличане на конкретни блокове по ID (layer 2), за да не се препраща целият пакет.
- FR1.4 — UI Inspector рендва token cost на блок + кумулативен „meter" спрямо budget.

### Non-functional
- NFR1.1 — оценката трябва да е евтина (engine я смята вече) и **консистентна** (един estimator: char/4 vs реален tokenizer — да се фиксира).
- NFR1.2 — **backward-compatible**: default поведението на `context_pack` за текущите MCP callers не се променя (нов флаг, не нова семантика).

### User stories / acceptance
- US1.1 — *Като агент* искам евтин манифест на кандидат-паметите с token cost, за да избера какво да заредя без да взривя budget.
  - AC: манифест-режим връща 0 тела; всеки ред има path + token estimate; сумата съвпада с реалния пакет при пълно зареждане (±estimator грешка).
- US1.2 — *Като потребител в UI* искам да виждам колко от контекста изяжда даден recall.
  - AC: Inspector показва per-block + кумулативна стойност; meter променя цвят при доближаване на budget.

### Open questions
- OQ1.1 — Estimator: char-heuristic (евтино, приблизително) или реален tokenizer (точно, по-скъпо)? Кое е приемливо?
- OQ1.2 — Layer-0 да е **нов флаг на `context_pack`** (`manifest: true`) или **отделен MCP tool**?
- OQ1.3 — Token cost нужен ли е и на MCP surface-а (за агента), или само в UI-а (за човека)?

---

## Идея 2 — `<private>` изключване от индексиране/recall

### Проблем
Чувствително съдържание (тайни, PII), написано в note, се индексира изцяло (FTS + bge-m3 embeddings) и се връща в recall/`context_pack` — изтича в agent context **и** в git история. Днес няма redaction на write-path (`write(path, content, expectedRevision)`; `redactRemote` е несвързано — само backup URL-и).

### Какво взаимстваме
Inline `<private>…</private>` маркер (или whole-note frontmatter флаг), който маха съдържанието от съхранение/recall.

### Критичен fork (Svod е git-backed — „изключване" е двусмислено)
- **Вариант A — exclude-from-index/recall:** note-ът пази съдържанието (source of truth, което човекът е написал), но private спанът **не влиза** в FTS index, embeddings, `search`, `context_pack`. Видим за собственика в нативния UI; невидим за агенти/recall.
- **Вариант B — strip-from-commit:** private спанът се маха **преди commit** — никога не влиза в git. По-силна гаранция, но губиш съдържанието и от собствения си vault.
- Естественият Svod split: **A + разделение по канал** — видимо през App API (UI на човека-собственик), скрито през MCP (агенти). Тайната остава в личния vault, но никога не стига до агент.

### Functional requirements
- FR2.1 — маркер: span-level (`<private>…</private>`) и/или note-level (frontmatter `private: true`).
- FR2.2 — маркираното се изключва от: FTS index, bge-m3 embeddings, `search` резултати, `context_pack` блокове, wikilink/graph извеждане.
- FR2.3 — политика по канал: скрито за MCP (агент); за App API (UI) — виждано от собственика (при вариант A).
- FR2.4 — детерминистично и **тестируемо** (recall никога не връща private съдържание).

### Non-functional / security
- NFR2.1 — попада в **high-risk „account-trust/leak"** категорията (CLAUDE.md) → задължителен self-review за изтичащи пътища преди merge.
- NFR2.2 — не чупи optimistic concurrency (`expectedRevision`).
- NFR2.3 — предпоставка за идея 3: auto-capture трябва да **уважава** `<private>`.

### User stories / acceptance
- US2.1 — *Като потребител* пиша тайна в note и тя никога не изплува в agent recall или embeddings.
  - AC: `search`/`context_pack` през MCP не връщат private текст при никаква заявка; embeddings не съдържат private токени.
- US2.2 — *Като потребител* маркирам цял note private → остава в моя vault, невидим за агенти.

### Open questions (трябва решение преди design)
- OQ2.1 — **Вариант A (exclude-from-index) или B (strip-from-commit)?** — определя цялата архитектура.
- OQ2.2 — Span-level, note-level, или и двете?
- OQ2.3 — Ретроактивно: public note → маркиран private по-късно. Git историята пази старото. Scrub на историята **out of scope** ли е (документирано ограничение) или изискване?
- OQ2.4 — Wikilink вътре в private спан — линкът брои ли се в графа?

---

## Идея 3 — Опционален lifecycle-hook auto-capture

### Проблем
Ценен контекст (взети решения, какво е пробвано) се губи, защото никой не спира да `remember`-не. Но auto-capture в curated git vault = **commit шум + замърсена памет** (изрично флагнато в доклада).

### Напрежение с идентичността на Svod
Svod = **умишлена, авторирана, версионирана** памет. Auto-capture противоречи. Помирение: capture в **карантинен namespace** (`messy/`), който **не е** в default recall, после `promote` на доброто (lifecycle-ът вече съществува: `messy/` → curated, provisional → active).

### Functional requirements
- FR3.1 — **opt-in** capture канал, пишещ observations в `messy/` с source attribution + session id + timestamp.
- FR3.2 — captured съдържание **изключено** от default `context_pack`/recall, докато не бъде promote-нато.
- FR3.3 — review/promote flow (преизползва съществуващия `promote`).
- FR3.4 — captured съдържание **уважава `<private>`** (идея 2) — без auto-capture на тайни.

### Non-functional
- NFR3.1 — нула commit шум в curated vault.
- NFR3.2 — ясно **opt-in**; изключено по подразбиране; не нарушава „deliberate" за главния vault.

### User stories / acceptance
- US3.1 — *Като потребител* искам опционален фонов capture на session-решения в review-опашка, без да замърся curated vault.
- US3.2 — *Като потребител* преглеждам captured observations и promote-вам полезните.

### Open questions (най-голямото решение)
- OQ3.1 — **Изобщо желано ли е**, при „deliberate" философията? (accept/reject — това е решение, не задача.)
- OQ3.2 — Източник на capture: **Claude Code hooks** на машината на потребителя (като claude-mem, пишещи през MCP `write` към `messy/`) **или engine-side** capture (engine вече вижда `agent.activity`/`commit.created`)?
- OQ3.3 — Гранулярност: всеки tool call = шум; per-session summary = полезно. Нужна ли е **LLM summarization** (claude-mem ползва Agent SDK)? Ако да — къде тече (engine няма LLM; трябва call-out)?

---

## Идея 4 — Real-time memory-stream viewer (enrichment на Activity)

### Проблем (най-малкият — способността вече я има)
`ActivityFeedView`/`ActivityModel` вече стриймват WS събития. Липсва **дълбочина**: кой агент, коя памет/revision, click-through към бележката, citation обратно към източника.

### Какво взаимстваме
От claude-mem viewer-а: citations по observation ID, „view all", richer per-event детайл, token-cost на последния recall (връзка с идея 1).

### Functional requirements
- FR4.1 — обогатяване на activity събитие с **agent identity** (llm-access registry вече съществува) + memory path + action type.
- FR4.2 — click върху събитие → отваря note-а на **тази revision** (преизползва `SidebarModel.reveal` + diff).
- FR4.3 — citations: `context_pack` блок ↔ source commit/събитие.
- FR4.4 — (връзка с идея 1) live token-cost на най-скорошния recall във feed-а.

### Non-functional
- NFR4.1 — да стои в **съществуващия WS event contract** — да не се измисля engine поведение (contract-gap правилото). Ако payload-ът не носи agent id / path, това е engine-промяна, не UI.
- NFR4.2 — dedupe вече е решен (`data.commit`).

### User stories / acceptance
- US4.1 — *Като потребител* кликам живо събитие и скачам на точната memory revision, която е променило.
- US4.2 — *Като потребител* виждам кой агент/MCP сесия е извършил всяко memory действие.

### Open questions
- OQ4.1 — Текущият event payload носи ли **agent identity** и **memory path**, или само commit id? (Определя дали е чисто UI или изисква engine-промяна.)
- OQ4.2 — Citation ID модел: по commit hash (Svod вече има) или отделен observation ID (claude-mem стил)?

---

## Cross-cutting изводи

- **Зависимости:** идея 2 е guardrail за идея 3. Идея 1 захранва идея 4 (token cost във feed-а). → не са независими.
- **Философска дисциплина:** идея 3 е единствената, която може да наруши идентичността на Svod. Карантина в `messy/` + opt-in я прави безопасна, но решението „изобщо да я правим ли" е на потребителя.
- **Contract discipline:** идеи 1 и 4 може да опрат до engine payload промени (token cost по MCP, agent id в event). Да се провери преди да се обещае чисто UI работа.

## Решения на потребителя (2026-07-07)
1. **Приоритет/обхват:** ⏸ Само докладите засега — без преминаване към `/sc:design`. Изборът кое да се поеме напред остава офлайн решение.
2. **`<private>` fork:** ✅ **Вариант A — exclude-from-index/recall.** Note-ът пази съдържанието (source of truth); private частта не влиза в FTS/embeddings/recall; видима за собственика в UI, скрита за MCP/агенти. Вариант B (strip-from-commit) отхвърлен.
3. **Auto-capture (идея 3):** ✅ Приема се, **но само като карантина в `messy/` + opt-in**, извън default curated recall, с ръчен `promote`. Не се налива в главния vault. Гейтната от идея 2 (не auto-capture-ва private/тайни).

**Статус:** requirements discovery завършен и замразен. Когато се реши да се поеме идея напред → `/sc:design` (архитектура + schema за избраната идея), или `/sc:workflow` за implementation план. Фиксираните по-горе решения (A за `<private>`, messy/-карантина за auto-capture) са вход за design фазата.
