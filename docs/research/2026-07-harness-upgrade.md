# Analýza upstreamů a návrh upgradu harnessu (červenec 2026)

Datum: 2026-07-24 · Stav harnessu: v0.2.1 · Interaktivní verze: `tmp/harness-upgrade-2026-07.html`

Tři paralelní průzkumy: (A) drift upstream repozitářů vůči našim vendorovaným
kopiím, (B) oficiální best practices a trendy agentního kódování, (C) ekosystém
UI skillů a odpověď na otázku „kam s nimi". Klíčová tvrzení o upstreamech byla
ověřena přímými diffy proti `raw.githubusercontent.com` (ne jen agentním
reportem); položky, které ověřeny nebyly, jsou označeny **[neověřeno]**.

---

## A. Upstream drift

Aktuální HEAD SHA (ověřeno `git ls-remote`, 2026-07-24):

| Repo | Naposledy revidováno | HEAD nyní |
|---|---|---|
| `mattpocock/skills` | `66f92b6` (2026-07-06) | `ed37663` |
| `vercel-labs/skills` | `3013fde` (2026-07-06) | `e173b8c` |
| `Archive228/loopkit` | ideas-only (~05/2026) | `5ae033e` |

### Ověřené změny v mattpocock/skills (66f92b6 → ed37663)

**Přejmenování (ověřeno: staré cesty vrací 404):**

- `to-issues` → **`to-tickets`** — a nejde jen o rename. Obsahové novinky:
  - každý ticket deklaruje **blocking edges** (které tickety ho blokují);
  - slice má být **sized to fit v jednom čerstvém context window**;
  - výslovná výjimka z vertical slicingu: **wide refactor** se sekvencuje jako
    **expand–contract** (expand vedle starého → migrace call sites po dávkách
    dle blast radius → contract), s integračním branchem, když dávky nemohou
    zůstat zelené samostatně;
  - „prefactoring first" („make the change easy, then make the easy change");
  - zmizelo HITL/AFK typování slices;
  - upstream přidal `disable-model-invocation: true`.
- `to-prd` → **`to-spec`** — terminologie PRD → spec; krok „sketch major
  modules / deep modules" nahrazen **seams-first** přístupem: preferovat
  existující seams, navrhovat nové co nejvýše, „ideální počet seams je jedna";
  `disable-model-invocation: true`.

**Nové skilly:**

- **`implement`** (engineering, 15 řádků) — tenký delegátor: /tdd na
  pre-agreed seams, „typecheck průběžně, jednotlivé test soubory průběžně, celá
  suite jednou na konci", pak /code-review, commit. Náš `implement-issue` je
  výrazně bohatší (issue → branch → TDD → reviewer agent → verify → PR).
- **`resolving-merge-conflicts`** (engineering, 14 řádků) — disciplína řešení
  merge/rebase konfliktů: primární zdroje → zachovat oba záměry → nikdy
  `--abort` → objevit a pustit automatické checky → dokončit. Samostatný, bez
  závislostí.
- **`wayfinder`** — graduoval z in-progress do engineering (128 řádků).
  Plánování obří práce jako mapa „decision tickets" na trackeru. Závisí na
  upstream `setup-matt-pocock-skills` tracker-doc infrastruktuře, kterou
  záměrně nevendorujeme; překrývá se s naším to-prd/to-issues/triage tokem.
- **`batch-grill-me`** (in-progress) **[neověřeno obsahově]** — hromadné
  grilování „všechny frontier otázky najednou, po kolech".

**Beze změny / status quo:** codebase-design, domain-modeling, diagnose,
improve-codebase-architecture, prototype, tdd, triage, research, handoff,
grilling, write-a-skill, to-issues resources — bez materiálního driftu
**[per agentní report; diffnuty jen to-tickets/to-spec/find-skills]**.
Divergence grill-me / grill-with-docs (upstream = tencí delegátoři, my =
self-contained) trvá a zůstává záměrná. `zoom-out` je upstream smazaný — náš
frozen stav platí. `caveman` dál frozen.

### vercel-labs/skills

`find-skills` drift je kosmetický (ověřeno diffem): `--owner <owner>` flag u
`npx skills find`, odstraněná zmínka o `npx skills check`. Levný sync.

### loopkit

Žádné nové koncepty od května 2026 (README beze změny struktury). Naše
re-engineering (verifier, autopilot, cost-discipline) zůstává aktuální.

### Doporučení k upstreamům (seřazeno)

| # | Akce | Priorita | Pracnost |
|---|---|---|---|
| 1 | **Sync `to-issues` ← `to-tickets`**: převzít blocking edges, context-window sizing, expand–contract pro wide refactory, prefactoring. Ponechat náš název `to-issues` jako **local patch** (vzor `diagnose`). Zvážit převzetí `disable-model-invocation`. | vysoká | S |
| 2 | **Sync `to-prd` ← `to-spec`**: převzít seams-first krok (kompatibilní s naším codebase-design slovníkem). Ponechat název `to-prd` jako local patch. | vysoká | S |
| 3 | **Vendorovat `resolving-merge-conflicts`** — malý, samostatný, doplňuje autopilot (konflikty při dlouhých bězích). | střední | S |
| 4 | **Nevendorovat `implement`**, ale vytěžit: přenést kadenci „typecheck průběžně / celá suite jednou na konci" do `implement-issue`. | střední | S |
| 5 | Sync `find-skills` (--owner flag). | nízká | S |
| 6 | Aktualizovat sync-log: nové SHA, wayfinder graduoval (skip trvá — závislost na tracker-doc + překryv s naším tokem), batch-grill-me na watch. | vysoká (spolu s 1–3) | S |

---

## B. Trendy agentního kódování → návrh upgradu harnessu

### Co říká oficiální guidance (Anthropic)

Zdroje: [Best practices for Claude Code](https://code.claude.com/docs/en/best-practices),
[Effective context engineering](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents),
[Steering Claude Code](https://claude.com/blog/steering-claude-code-skills-hooks-rules-subagents-and-more),
[Building multi-agent systems](https://claude.com/blog/building-multi-agent-systems-when-and-how-to-use-them),
[Skill authoring best practices](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices).

1. **Verifikační smyčka je jádro**: dej agentovi check, který si umí pustit
   sám (testy, build, screenshot diff) — bez něj jsi verifikační smyčkou ty.
   Čtyři úrovně: v promptu → per-session cíl → **deterministický Stop-hook
   gate** (exit 2 dokud check neprojde; override po 8 blocích) → nezávislý
   verifikační subagent. Harness má úrovně 1 a 4 (verifier), chybí turnkey
   úroveň 3.
2. **Multi-agent jen při reálném omezení** (context protection, paralelizace,
   specializace); dekompozice **podle kontextu, ne podle fází problému**
   (žádný planner/implementer/tester split). Verifikační subagent je výslovně
   zmíněný jako pattern, který funguje — náš `verifier` je přesně to.
3. **Progressive disclosure**: SKILL.md < 500 řádků, reference files max
   1 úroveň od SKILL.md, gerund naming, description ve 3. osobě (co + kdy).
   CLAUDE.md < ~200 řádků; „if removing this causes mistakes, keep it —
   otherwise cut it."
4. **Lean on the model**: pravidelně škrtat workaroundy pro starší modely;
   hooks pro vše, co má být deterministické, ne advisory.

### Komunita: loops a „graph engineering"

- **Ralph-Wiggum loop** (fresh-context iterace, spec + stav na disku, žádná
  historie konverzace mezi iteracemi) je v polovině 2026 nejdiskutovanější
  pattern autonomního kódování. **Náš `autopilot` tohle už dělá** — fresh
  kontext, stav v `tmp/autopilot/`, verify gates, checkpointy. Trend nás
  validuje; nepřepisovat, jen dílčí vylepšení.
- **Code graphs / repo maps** („graph engineering"): AST/import indexy repa
  poskytnuté agentovi, aby nemusel každou iteraci znovu objevovat strukturu.
  Hlášené přínosy ~10× úspora tokenů a ~2× méně tool-calls na velkých repech
  **[čísla neověřena, komunitní zdroje]**. Princip: *„graf říká, kam se
  dívat; soubor, test a runtime říkají, co je pravda."* Fresh-context loop
  tuhle potřebu násobí — každá iterace autopilota dnes strukturu objevuje
  znovu.

### Roadmapa upgradu (effort × impact)

| # | Návrh | Effort | Impact | Poznámka |
|---|---|---|---|---|
| U1 | **Stop-hook verify gate šablona** (`require-verify-before-stop`): opt-in hook v `templates/`, čte `tmp/.last-verify-status`, exit 2 dokud verify neprošel. Náš default „Stop hooks always exit 0" zůstává; tohle je vědomá opt-in vrstva pro unattended běhy (autopilot ji může zapínat sám). | S | vysoký | oficiální pattern, úroveň 3 verifikace |
| U2 | **Doktrína do docs + write-a-skill**: context-centric decomposition (kdy ne-multi-agent), progressive-disclosure limity (500 řádků, 1 úroveň), gerund naming, description-ve-3.-osobě checklist. | S | střední | levné, zvyšuje kvalitu všech budoucích skillů |
| U3 | **Repo-map vrstva („graph engineering")**: `code-map` už parsuje import graf pro HTML — přidat druhý výstup `tmp/repo-map.json` (moduly, hrany, in/out degree) + mini skill `repo-map` pro dotazy „co importuje X / dopad změny Y". Bez MCP (záměr repa), čistý soubor na disku; autopilot si ho načte na startu iterace. | M | vysoký | nezávislý nástroj, přesně „další vrstva" z otázky uživatele |
| U4 | **Autopilot tune-up**: per-iteration spec soubor (`tmp/autopilot/iteration-N.md`), metriky do run-logu (tool-calls-before-first-edit, verify-fail rate), volitelné napojení na U1 a U3. | M | střední | validace Ralph-Wiggum trendem; evoluce, ne přepis |
| U5 | **Watch-list** (nestavět bez ověření v oficiálních docs): Agent Teams orchestrace, nested subagents, adaptivní volba modelu dle složitosti, `/goal`. Research je hlásí jako dostupné **[neověřeno]** — před použitím ověřit na code.claude.com/docs. | — | — | riziko nadhodnocení featur agentním researchem |

Pořadí realizace: **1–3 z části A + U1 + U2** (jeden PR, samé S), pak **U3**,
pak **U4**. U5 průběžně.

---

## C. UI skills — koncept „design lane"

**Otázka:** harness udělá věci funkční, ale UI se ladí ručně; jak efektivně
zapojit ui-skills.com a podobné? Patří to do tohoto projektu?

**Odpověď: nepatří — samostatný plugin ve stejném marketplace.** Tento repo
už je vlastní marketplace (`.claude-plugin/marketplace.json`), takže druhý
plugin je jen další záznam; může žít ve vlastním repu (doporučeno) nebo jako
druhý plugin-dir.

Důvody oddělení:

1. **Jiný concern**: harness = workflow (issues → TDD → review → autopilot);
   design skilly = vkus a vizuální iterace. Backend projekty nemají platit
   kontextem za design tooling.
2. **Stack-specificita**: `baseline-ui` z ui-skills.com mandatuje
   Tailwind + motion/react + Base UI/Radix — to do univerzálního harnessu
   nesmí; v opt-in design pluginu je to legitimní volba.
3. **Vizuální feedback loop není skill, ale infrastruktura**: screenshot →
   kritika → fix vyžaduje browser tooling. Dvě varianty: Playwright MCP
   (plný a11y tree, ~114k tokenů/task) vs. **CLI snapshot** (~27k tokenů/task,
   ~4× levnější) **[čísla z komunitních zdrojů]**. Doporučení: CLI-snapshot
   jako default, MCP jako opt-in.

### Inventář ekosystému (07/2026)

| Zdroj | Co to je | Licence/pozn. |
|---|---|---|
| [ibelick/ui-skills](https://github.com/ibelick/ui-skills) (ui-skills.com) | `baseline-ui` (opinionated standardy: Tailwind, motion/react, a11y, typografie), `fixing-motion-performance` (audit animací, transform/opacity pravidla, paint budget) aj.; distribuce `npx ui-skills` | MIT, ~6.2k★ |
| [Anthropic frontend-design](https://github.com/anthropics/claude-code/blob/main/plugins/frontend-design/skills/frontend-design/SKILL.md) | oficiální design-filozofie skill (anti-default: žádný „Inter + purple gradient", nejdřív design tokens, pak kód) | oficiální plugin, stack-agnostic |
| Superdesign (superdesign.dev) | design-orchestrace, oddělení design fáze od kódu | MCP-based |
| LibreUIUX, ui-ux-pro-max | rozsáhlé kolekce design principů / palet / typografie | framework-agnostic, objemné |
| Playwright screenshot loop | vizuální feedback smyčka (viz výše) | infrastruktura, ne skill |

### Navržená struktura `design-harness`

```
design-harness/                      (nový repo, listovaný v našem marketplace.json)
├── .claude-plugin/plugin.json
├── skills/
│   ├── baseline-ui/                 (vendored ibelick, MIT — sync-log stejně jako u Pococka)
│   ├── fixing-motion-performance/   (vendored ibelick)
│   ├── design-first/                (own; filozofie po vzoru Anthropic frontend-design)
│   ├── ui-polish-loop/              (own; screenshot → kritika → fix, CLI-snapshot)
│   └── design-review/               (own; post-implementation audit: a11y, kontrast, responsivita, motion)
├── docs/vendor-sync-log.md          (stejná disciplína jako zde)
└── templates/design-tokens.template.md
```

Konvence pro konzumní projekty: `.claude/skills/design-tokens/` = projektový
brand-system override (paleta, typografie, spacing), který `ui-polish-loop`
a `design-review` čtou jako zdroj pravdy. Dělba: **harness** dodá funkčnost
a workflow, **design-harness** dodá vkus a vizuální iteraci, **projekt** dodá
brand. Skilly obou pluginů se nekříží (namespacing `plugin:skill`).

MVP pořadí: (1) repo + marketplace záznam + vendor baseline-ui a
fixing-motion-performance, (2) `ui-polish-loop` se screenshot skriptem,
(3) `design-review`, (4) `design-first`.

---

## Souhrn doporučení

1. **Hned (jeden vendor-sync PR, vše S):** sync to-tickets → to-issues,
   to-spec → to-prd, vendor resolving-merge-conflicts, sync find-skills,
   aktualizace sync-logu; + U1 (Stop-hook verify gate šablona) a U2 (doktrína
   do docs/write-a-skill).
2. **Další iterace (M):** U3 repo-map.json + `repo-map` skill — „graph
   engineering" vrstva; poté U4 autopilot tune-up.
3. **Paralelně, nový repo:** `design-harness` plugin (design lane) dle části C.
4. **Nestavět bez ověření:** položky watch-listu U5.

### Zdroje

- code.claude.com/docs/en/best-practices · /docs/en/hooks · /docs/en/plugins
- anthropic.com/engineering/effective-context-engineering-for-ai-agents
- claude.com/blog: steering-claude-code…, building-multi-agent-systems…, harnessing-claudes-intelligence, improving-frontend-design-through-skills
- platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices
- github.com/mattpocock/skills @ ed37663 · github.com/vercel-labs/skills @ e173b8c · github.com/Archive228/loopkit @ 5ae033e (diffy 2026-07-24)
- github.com/ibelick/ui-skills · superdesign.dev · ralph-wiggum.ai · codecentric.de (Ralph Wiggum loop) · developersdigest.tech (code graphs) · arxiv 2603.27277 (tree-sitter knowledge graphs)
