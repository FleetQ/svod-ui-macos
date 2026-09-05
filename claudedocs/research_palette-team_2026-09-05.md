# Palette (palette.team) — какво можем да заимстваме за Svod

Дата: 2026-09-05 · Дълбочина: standard · Метод: 20 страници от palette.team (сайт, docs, blog, pricing, marketplace), сравнени срещу текущото състояние на Svod (engine v1.19.1 / contract 0.29.0, app v0.2.21) по Serena паметите и по grep в `Svod/`.

## Резюме

Palette Desktop е macOS приложение, което хоства **чат с агенти** (Claude Code, Codex, Gemini CLI, Mistral Vibe, собствен агент) върху **папка с markdown**. Ключовата им идея е **session = sandbox клонинг на папката**: агентът пише в клонинга, човекът гледа diff и „save back" в основната папка. Целта е екипна работа върху споделена папка (Drive/Dropbox) без терминал.

Svod и Palette решават една и съща основна задача (папка с markdown като контекст за агенти), но от двата края:

| | Svod | Palette |
|---|---|---|
| Кой хоства агента | външен, през MCP (:7620) | вътре в приложението (чат) |
| Запис от агент | директен commit, история + restore | staged в клонинг, review преди save-back |
| Сливане | git 3-way merge, 409 conflict, Sources conflicts | „cloud sync is not our merge engine", конфликтен диалог при Update/Save |
| Търсене | FTS + bge-m3 вектори + reranker, GraphRAG теми | няма (агентът чете папката) |
| Памет | capture → distill → proposals; graph summaries | Context Library (седмично генерирани страници, private preview) |
| Аудитория | един човек, няколко машини | екип, не-инженери |

Оценка: **Svod е пред Palette в инфраструктурата** (retrieval, граф, история, конфликти, sync). **Palette е пред Svod в човешкия workflow около агентските промени** и в няколко евтини UX детайла. Оттам идват идеите.

## Идеи, подредени по стойност

### Ниво A — реални дупки в Svod

**1. Преглед на агентски промени (post-hoc review).**
Palette: всеки session записва в клонинг, човекът вижда списък с променени файлове + red/green diff, одобрява всеки и чак тогава се save-ва обратно.
Svod днес: всеки MCP `write`/`edit` става commit веднага. History има Restore (проверено: `HistoryView.swift:43`), но Activity feed има само „jump" към бележката (`ActivityFeedView.swift:122`). Няма понятие „непрегледано".
Какво да заимстваме, в два размера:
- **Лек вариант (препоръчван първи):** Activity получава състояние „reviewed / unreviewed" за агентски commit-и (маркер локално в приложението или в engine-а), филтър „Unreviewed", и inline diff + бутон „Revert" (= restore на предишната ревизия, което вече е „write old content as new commit"). Не пипа engine-ния модел на запис. Дава 80% от ползата без sandbox.
- **Тежък вариант:** роля `WRITE_STAGED` за агент в LLM Access. Записите му отиват в git branch `refs/svod/staging/<agentId>` вместо в main; UI показва staged diff с Accept/Discard; Accept = merge. Git-ът вече е там, но това е нова engine повърхност (routing, index на staged съдържание, conflict при accept) и променя философията „агентът е пълноправен писател".
Защо е А: Palette съществува заради тази нужда и всичките им отзиви са за нея. За Svod, където агентите пишат в личния vault на човека без наблюдение, „какво написа агентът, докато ме нямаше" е същият проблем.

**2. HTML preview във viewer-а.**
Palette рендва `.html` направо в приложението и го промотира като формата за „AI output за хора" (доклади, прототипи, decks като един self-contained HTML файл).
Svod днес: WKWebView + CodeMirror вече са там, но `.html` се показва като код (проверено: единствените „html" съвпадения в `Svod/` са коментари; `editor.src.js` няма HTML рендер режим). Агентите вече пишат доклади във vault-а, а доклад в HTML днес е нечетим в Svod.
Обем: малък. Трети режим в bridge-а (`setLanguage` вече знае разширението) + рендер в sandboxed iframe/втори WKWebView. Внимание на скриптове от агентски HTML: sandboxed iframe без network.

### Ниво B — евтини UX подобрения, доказано полезни при тях

**3. Pinned бележки в sidebar-а („Shortcuts").**
Palette: pin на файл или prompt, „личен, не се синхронизира". Svod има Saved Searches (`SidebarView.swift:404`), но не и pinned бележки. Секция „Pinned" над дървото, persist в UserDefaults per-vault. Обем: малък.

**4. Prompt-ове/skills живеят във vault-а, не в конфигурация.**
Palette: „Actions live in the workspace folder as plain markdown. Anyone who has the folder has them." Списък с наличните actions вътре в чата.
Svod днес: system prompt-ът на агент е поле `prompt` в engine config JSON (LLM Access). Не е версиониран, не се търси, не се редактира в редактора.
Заемка: конвенция `_svod/agents/<agentId>.md` във vault-а (или reference от config към път във vault-а). Печели версия/история/търсене безплатно от engine-а. Svod няма чат, така че „run action" не е приложимо; само съхранението и surfacing-ът са.

**5. Шаблони при Create Vault.**
Palette Marketplace: „folder systems" (company-os, project-os с `decisions/` номерирани записи, `meetings/`, `overview.html` dashboard). Svod има Create Vault flow без стартова структура. Две-три вградени структури (personal / project / research) + стартов `agents/` prompt. Обем: малък до среден. Стойност: средна, vault-ът обикновено се import-ва, не се създава празен.

### Ниво C — интересни, но не сега

**6. Човешки вход в генерирания контекст.**
Palette Context Library: „tool events arrive throughout the week, and **check-ins add the meaning only people can provide**", седмична регенерация. Svod вече има точно това от машинната страна: GraphRAG summaries с `rebuildIntervalMinutes 10080` (седмица) и recall distill. Липсва обратната посока: човекът да закачи/коригира summary на тема, и rebuild-ът да пази ръчния override. Идея за след като hierarchical build се пусне реално.

**7. Handoffs (private preview при тях).** „Carry decisions, progress, files, next steps from one person or agent to the next." При нас: capture + `.continuity/STATE.md` + Svod notes. Един типизиран `handoff` note kind в `remember` би го формализирал. Нищо не е доказано и при тях.

**8. Positioning.** Техният манифест: „the session is the new unit of knowledge work; the reasoning disappears into AI sessions the rest of the organization cannot see". Това е буквално Svod capture/distill. И „the folder is the workspace, no database, if you stop using Palette your folder is still your folder" важи и за Svod (git + markdown, `.svod/` е само индекс). Ако Svod някога има README/landing, тези две изречения са готови.

## Вече го имаме (не заимстваме)

- **Update session / конфликти при save-back** → Svod: 409 `ConflictBody` + 3-way merge sheet, editor reconcile при `file.changed`, Sources conflicts + resolve. Palette изрично казва, че cloud sync не е merge engine. Тук сме по-силни.
- **References (външни папки, read-only/editable)** → Svod Sources с `writeBack` и two-sided manifest. Еквивалент, по-робастен.
- **Agent-agnostic + Connector Gateway („connect once, use across agents")** → това е MCP на :7620 с agent tokens; claude-code, claude-desktop, lm-studio вече са регистрирани.
- **Per-chat permissions** → per-agent role READ_ONLY|WRITE + vault scoping. По-грубо от per-session, достатъчно за един потребител.
- **Frontmatter като форма** → properties panel.
- **Changes history: browse, compare, restore** → History pane.
- **Multi-machine** → git sync bus на `refs/svod/sync/<vault>` срещу Dropbox при тях.

## Съзнателно не искаме

- **Чат в приложението / вграден агент с on-device модел.** Решено в recall спринта: engine-ът е data plane, генеративният LLM стои отвън (`claude -p`, MCP клиенти). Palette агентът е цял harness; това е друг продукт.
- **Екипно споделяне през Drive/Dropbox.** Svod е single-user, multi-machine, с git като bus. Екипен Svod би било продуктов pivot, не заемка.
- **Plan mode.** Страна на агента, не на хранилището.

## Препоръка (за решение от теб)

1. Направи **#2 HTML preview** и **#3 Pinned** като един малък app release. Нулев engine риск.
2. Реши между лекия и тежкия вариант на **#1**. Моята препоръка е лекият (Activity review + Revert): ползата е в „какво стана, докато ме нямаше", а не в sandbox-а, който при Palette съществува заради екипа.
3. **#4** (prompt-ове във vault-а) е малка engine промяна с ясна полза; може да върви със следващия engine release.
4. #5, #6, #7 в backlog.

Следваща стъпка: `/sc:design` за #1 ако избереш тежкия вариант; директно `/sc:implement` за #2/#3.

## Доверие

- Какво прави Palette: **високо**, четено от собствената им документация (docs с дати 2026-07-22 … 2026-08-10).
- Какво липсва в Svod: **високо** за HTML preview, pinned, Activity revert (grep в `Svod/` + Serena памети); **средно** за точния обем на #1 тежък вариант (не съм чел engine кода за routing/index в тази сесия).
- Palette OS (Context Library, Skills, Handoffs, Connector Gateway) е **private preview**; описанията са намерения, не доставен продукт.

## Източници

- https://palette.team/ · https://palette.team/desktop · https://palette.team/pricing · https://palette.team/os · https://palette.team/marketplace
- Docs: /docs/welcome-to-palette · /docs/palette-desktop-overview · /docs/palette-desktop-agents · /docs/palette-desktop-palette-agent · /docs/palette-desktop-sessions · /docs/palette-desktop-workspaces · /docs/palette-desktop-chats · /docs/palette-desktop-references · /docs/palette-desktop-actions · /docs/palette-desktop-shortcuts · /docs/palette-desktop-the-viewer · /docs/palette-desktop-editing-markdown · /docs/palette-desktop-working-with-html-files · /docs/palette-desktop-plan-mode · /docs/palette-desktop-sharing-workspaces · /docs/welcome-to-palette-shared-context-for-teams-and-ai · /docs/palette-manifesto-why-context-is-infrastructure · /docs/frequently-asked-questions
- Blog: /blog/launching-palette-desktop (2026-05-19) · /blog/announcing-our-pre-seed (2026-08-11)
- Svod: Serena `svod-ui-architecture`, `svod-ui-llm-access`, `svod-recall-memory-sprint`, `svod-sources-conflicts-writeback`, `svod-claude-mem-borrowed-ideas`, `svod-hardening-sprint-2026-08-17`, `svod-ui-webeditor-file-types`, `svod-ui-search-sidebar-ux`; auto-memory `svod-multimachine-sync`, `svod-ui-code-file-preview`.
- Предишни „borrowed ideas" оценки за сравнение на метода: `claudedocs/research_claude-mem_evaluation_2026-07-07.md`, `claudedocs/research_recall-persistent-memory_2026-07-15.md`.
