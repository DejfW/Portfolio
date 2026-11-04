# Strona portfolio w stylu n8n — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Zbudować graficzną stronę portfolio z listą projektów, na której automatyzacja sklepu z meblami jest pierwszym projektem, a kolejny (np. orkiestrator agentów) dodaje się jednym folderem i jedną linijką w manifeście.

**Architecture:** Statyczny serwis bez bundlera i bez zależności (HTML, CSS, ES modules) w `portfolio/`. Cała treść projektów leży w `portfolio/projects/<slug>/project.json` (karta + lista typowanych bloków: tekst, tabela, lista, galeria screenów i nagrań, diagram, wykres, graf zależności) i jest renderowana w przeglądarce przez DOM API, nigdy przez `innerHTML`. Jeden walidator (`schema.js`, działa w przeglądarce i w Node) pilnuje danych: CLI `scripts/validate-portfolio.mjs` i testy używają tego samego kodu.

**Tech Stack:** HTML5, CSS custom properties, vanilla ES modules, `node:test` (zero zależności, jak `n8n/test`), mały serwer `scripts/serve-portfolio.mjs`, DM Sans (Google Fonts) jako zamiennik Geomanist.

**Spec:** `portfolio/DESIGN.md` (Task 1, Step 1 kopiuje go z `/Users/dawid/Downloads/DESIGN.md`, opisuje styl n8n) oraz wymagania z rozmowy w sekcji Global Constraints. Treść pierwszego projektu pochodzi z `README.md` i `docs/` tego repo.

## Global Constraints

- Styl: wyłącznie tokeny z `portfolio/DESIGN.md`. Tło strony `#0e0918`, karty `#1a1624` / `#1b1728`, tekst `#d1cece`, tekst drugorzędny `#9d9797`, obramowania `#3e3a46`.
- Typografia: tylko wagi 300 i 400. Display 54px / line-height 0.88 / letter-spacing -1.08px; nagłówek sekcji 48px; body 16px / 1.5. Czysta biel `#ffffff` tylko w nagłówkach.
- Gradient Ember (`linear-gradient(30deg, rgb(253,137,37), rgb(255,12,0))`) wyłącznie na `.btn-primary`. Gradient Electric Current (`linear-gradient(141deg, #077ac7, #6b21ef)`) wyłącznie na podkreśleniach linków, focus ringach i liniach połączeń w grafie.
- Elevation przez kolor tła, bez zewnętrznych cieni. Dozwolone `box-shadow`: `none`, `var(--shadow-subtle-2)` (inset), `var(--shadow-sm)` (halo tylko `.btn-frosted`).
- Promienie: przyciski i inputy 8px, karty 16px, panele 24px, badge 24px, piguły 9999px tylko dla tagów i statusów.
- Wszystkie kolory w `portfolio/css/base.css` i `components.css` przez `var(--…)`; literały hex/rgb wolno tylko w `tokens.css`.
- Brak `innerHTML`, `outerHTML`, `insertAdjacentHTML`, `document.write` w `portfolio/js/`. Tekst z JSON-a trafia do DOM przez `textContent`.
- Ścieżki mediów w JSON-ie: względne do folderu projektu, bez `..`, bez `/` na początku, bez schematu i bez `\`. Linki zewnętrzne tylko `http:` i `https:`.
- Dozwolone rozszerzenia mediów: obrazy `png jpg jpeg webp gif svg`, wideo `mp4 webm`. Wideo bez autoodtwarzania (`controls`, `preload="metadata"`, `playsinline`).
- Slug: `^[a-z0-9]+(-[a-z0-9]+)*$`, równy nazwie folderu. Folder zaczynający się od `_` (np. `_template`) nie jest projektem.
- Cała treść widoczna na stronie (UI, opisy projektów, `alt`, komunikaty błędów, `<html lang="en">`) jest po angielsku. Polskie źródła z README tłumaczysz, nie kopiujesz. Dokumentacja dla autora (`docs/`, ten plan) zostaje po polsku.
- Wszystkie fakty o projekcie (liczby, nazwy workflowów) pochodzą z repo (komendy w Task 7), nie z pamięci. Dane osobowe i kontaktowe (nazwisko, e-mail, bio, CV) wpisuje autor w `portfolio/site.json`; nie wolno wstawiać adresu e-mail ani nazwiska, których nie ma w repo. Link do GitHuba: `https://github.com/DejfW`.
- CV to opcjonalny plik `portfolio/assets/cv.pdf` dostarczony przez autora. Gdy `site.json` nie ma pola `cv`, żaden przycisk CV się nie renderuje; gdy jest, plik musi istnieć (walidator).
- `prefers-reduced-motion: reduce` wyłącza wszystkie animacje. Układ działa od 375px szerokości bez poziomego scrolla.
- Serwer deweloperski: port domyślny 8090 (8080 zajmuje `scripts/serve-web.mjs`).

## Review Focus

1. Tekst w JSON-ie zawiera `<script>`, `<img onerror=…>` albo `javascript:` w linku: wyświetla się dosłownie / zostaje odrzucony, nic się nie wykonuje. Testy: Task 1 `rejects javascript: link url`, Task 3 `no-unsafe-dom`.
2. Adres `project.html?p=../../etc/passwd` albo nieistniejący slug: strona „Project not found” z linkiem powrotnym, bez żądania sieciowego o dziwną ścieżkę. Test: Task 3 `parseSlug`, Task 4 w przeglądarce.
3. Manifest wskazuje projekt z brakującym lub uszkodzonym `project.json`: strona główna pokazuje pozostałe projekty, a CLI kończy się błędem. Testy: Task 3 `loadProjects skips broken project`, Task 1 `cli exits 1 on invalid project`.
4. Ścieżka mediów ucieka z folderu (`../../.env`, `/etc/passwd`, `https://obcy/x.png`) albo wskazuje nieistniejący plik: walidator odrzuca. Testy: Task 1.
5. Nagranie `.mp4` nie da się przewijać, bo serwer nie obsługuje `Range`: serwer odpowiada 206 / 416. Testy: Task 2.

---

### Task 1: Schemat danych, walidator i manifest projektów

**Files:**
- Create: `portfolio/DESIGN.md` (kopia `/Users/dawid/Downloads/DESIGN.md`)
- Create: `portfolio/js/lib/schema.js`
- Create: `portfolio/test/schema.test.mjs`, `portfolio/test/validate-cli.test.mjs`
- Create: `scripts/validate-portfolio.mjs`
- Create: `portfolio/projects/index.json`, `portfolio/projects/_template/project.json`
- Create: `portfolio/projects/meble-automatyzacja/project.json` (zalążek: status `shipped`, tagline, summary, jedna sekcja `prose`; pełną treść dodaje Task 7)
- Create: `portfolio/projects/orkiestrator-agentow/project.json` (status `planned`, title „Agent Orchestrator”, tagline „Coordinating multiple AI agents on one task”, tagi `["AI agents","orchestration"]`)

**Interfaces:**
- Produces (`portfolio/js/lib/schema.js`, bez importów Node, działa w przeglądarce):
  ```js
  export const STATUSES = ['shipped', 'in-progress', 'planned'];
  export const BLOCK_TYPES = ['prose', 'list', 'table', 'gallery', 'diagram', 'chart', 'graph'];
  export function isSafeRelPath(p: unknown): boolean;   // reguły ścieżek z Global Constraints
  export function isSafeUrl(u: unknown): boolean;       // tylko http(s)
  export function validateProject(project: object, ctx: { slug: string, fileExists: (rel: string) => boolean }): string[];
  export function validateManifest(manifest: object): string[];
  export function validateSite(site: object, ctx: { fileExists: (rel: string) => boolean }): string[];
  ```
  `site.json`: `name` (wymagane), `headline` (wymagane), `about: {title?, paragraphs: string[]}` , `highlights?: {title,text}[]` (kafelki w „About”), `skills?: {group: string, items: string[]}[]`, `links: {label,url}[]` (wymagany GitHub `https://github.com/DejfW`; e-mail jako `mailto:` dozwolony tylko w `links`, `isSafeUrl` dopuszcza dla niego `mailto:`), `cv?: {label, url}` gdzie `url` to `isSafeRelPath` do pliku `.pdf` (plik musi istnieć). Błędy w formacie jak wyżej, ścieżki np. `cv.url`.
  Błędy to napisy `"<ścieżka>: <komunikat>"`, np. `sections[2].items[0].src: file not found`.
- Format `project.json`: `slug`, `title`, `status`, `tagline` (≤140 znaków), `summary?`, `year?` (int), `role?`, `tags?: string[]`, `cover?` (ścieżka obrazu), `links?: {label,url}[]`, `stats?: {value,label}[]`, `sections?: Block[]`. Dla `status != "planned"` wymagane są `summary` i niepusta `sections`.
- Bloki: `prose {title?, paragraphs: string[]}`, `list {title?, items: {title,text}[]}`, `table {title?, columns: string[], rows: string[][]}`, `gallery {title?, items: ({type:"image",src,alt,caption?} | {type:"video",src,poster?,caption?})[]}` (pusta lista dozwolona), `diagram {title?, src, alt, caption?}`, `chart {title?, unit?, bars: {label, value≥0}[]}`, `graph {title?, nodes: {id,label,layer≥0 int,kind?: "channel"|"workflow"|"db"|"ai"|"output"}[], edges: {from,to}[]}`. Krawędź musi łączyć istniejące węzły i prowadzić do wyższej `layer`.
- Manifest `portfolio/projects/index.json`: `{"projects": ["meble-automatyzacja", "orkiestrator-agentow"]}`; kolejność = kolejność na stronie.

- [ ] **Step 1: Skopiuj spec do repo**

Run: `mkdir -p portfolio/test portfolio/js/lib portfolio/projects && cp /Users/dawid/Downloads/DESIGN.md portfolio/DESIGN.md`
Expected: `portfolio/DESIGN.md` istnieje (425 linii).

- [ ] **Step 2: Napisz testy `portfolio/test/schema.test.mjs` (node:test, assert/strict)**

Nazwy i asercje, każdy test buduje poprawny projekt pomocnikiem `ok()` i psuje jedno pole:
  - `valid planned project passes` → `validateProject(planned, ctx)` deep-equals `[]`.
  - `valid shipped project with every block type passes` → `[]`.
  - `slug must equal folder name` → błąd zaczyna się od `slug:`.
  - `planned project does not need sections` → `[]`; `shipped without sections` → błąd `sections:`.
  - `rejects javascript: link url` (`links[0].url = 'javascript:alert(1)'`) → błąd zaczyna się od `links[0].url:`; `isSafeUrl('https://github.com/x') === true`, `isSafeUrl('data:text/html,x') === false`.
  - `rejects media path escape` → dla `'../../.env'`, `'/etc/passwd'`, `'https://obcy/x.png'`, `'a\\b.png'`, `'media/x.exe'` `isSafeRelPath` jest `false`, a `'media/a.png'` `true`; `gallery.items[0].src` ze złą ścieżką daje błąd z `.src:`.
  - `rejects missing media file` (`fileExists: () => false`) → błąd kończy się `file not found`; dotyczy też `cover`, `poster`, `diagram.src`.
  - `image requires alt`, `video does not require alt`.
  - `table row length must match columns`.
  - `graph edge must reference known nodes and go to a later layer` (trzy podprzypadki).
  - `chart rejects negative and non-finite values`.
  - `unknown block type names the type` → komunikat zawiera `'sparkles'`.
  - `manifest rejects duplicate and invalid slugs`; `manifest accepts valid`.
  - `site accepts minimal valid site and optional cv absent`; `site rejects cv that is not a .pdf or is missing on disk` (`cv.url:`); `site rejects javascript: link`; `site allows mailto: only in links`.

- [ ] **Step 3: Uruchom testy, upewnij się, że padają**

Run: `node --test portfolio/test/schema.test.mjs`
Expected: FAIL (`Cannot find module .../schema.js`).

- [ ] **Step 4: Zaimplementuj `portfolio/js/lib/schema.js` według sygnatur wyżej**

Jedna funkcja walidująca na typ bloku, wybierana z mapy `BLOCK_TYPES → validator`; wspólny pomocnik `checkMedia(path, value, ctx, errors, {exts})`.

- [ ] **Step 5: Uruchom testy, upewnij się, że przechodzą**

Run: `node --test portfolio/test/schema.test.mjs`
Expected: PASS, 0 fail.

- [ ] **Step 6: Napisz test CLI `portfolio/test/validate-cli.test.mjs`**

Buduje w `os.tmpdir()` katalog `projects/` z manifestem i jednym projektem (`spawnSync(process.execPath, ['scripts/validate-portfolio.mjs', '--root', tmp])`):
  - `cli exits 0 on valid tree` → status 0, stdout zawiera `OK`.
  - `cli exits 1 on invalid project` (projekt z `javascript:` w linku) → status 1, stderr zawiera `links[0].url`.
  - `cli exits 1 when manifest lists missing folder` → status 1, stderr zawiera nazwę slugu.
  - `cli warns about folder not in manifest` → status 0, stdout zawiera `WARN` i nazwę folderu; folder `_template` jest pomijany.
  - `cli warns about empty gallery` → status 0, stdout zawiera `WARN`.

- [ ] **Step 7: Zaimplementuj `scripts/validate-portfolio.mjs [--root <portfolio/projects>]`**

Domyślny root: `portfolio/projects` względem repo. Czyta manifest i `project.json` każdego sluga, woła `validateManifest`/`validateProject` z `fileExists` opartym o `fs.existsSync` w folderze projektu; dodatkowo waliduje `<root>/../site.json` przez `validateSite` (`fileExists` względem `portfolio/`). Błędy na stderr, `exit 1`; ostrzeżenia na stdout; przy sukcesie `OK: N projects`.

- [ ] **Step 8: Utwórz dane**

`projects/index.json`, `_template/project.json` (pełny wzór z jednym blokiem każdego typu i komentarzowymi wartościami zastępczymi; ścieżki mediów w szablonie ominięte, bo `_template` nie jest walidowany jako projekt), zalążek `meble-automatyzacja` i `orkiestrator-agentow`.

- [ ] **Step 9: Uruchom wszystko**

Run: `node --test portfolio/test/ && node scripts/validate-portfolio.mjs`
Expected: wszystkie testy PASS, `OK: 2 projects`.

- [ ] **Step 10: Commit**

```bash
git add portfolio scripts/validate-portfolio.mjs
git commit -m "feat(portfolio): schemat danych projektów, walidator i manifest"
```

---

### Task 2: Serwer deweloperski, tokeny i reguły stylu

**Files:**
- Create: `scripts/serve-portfolio.mjs`
- Create: `portfolio/test/server.test.mjs`
- Create: `portfolio/css/tokens.css`, `portfolio/css/base.css`
- Create: `portfolio/test/design-rules.test.mjs`

**Interfaces:**
- Produces: `export function createPortfolioServer(rootDir: string): http.Server` (z `scripts/serve-portfolio.mjs`; uruchomiony bezpośrednio słucha na `process.argv[2] || 8090`).
- Produces (CSS): wszystkie zmienne z sekcji „Quick Start → CSS Custom Properties” z `portfolio/DESIGN.md` w `tokens.css`, plus pochodne tokeny potrzebne w komponentach (np. `--color-focus-ring`, `--color-overlay`, `--color-line`). `base.css`: reset, `body` (tło `--surface-void-base`, kolor `--color-ash-text`, font `--font-geomanist`), klasy `.container` (max 1200px, padding boczny 24px), `.section` (odstęp pionowy 80–120px), skala typografii `.t-display`, `.t-heading-lg`, `.t-heading`, `.t-body`, `.t-caption`, styl linków z podkreśleniem Electric Current, `:focus-visible` z ringiem Electric Current.

- [ ] **Step 1: Napisz `portfolio/test/server.test.mjs`**

Tworzy fixture w `os.tmpdir()` (`index.html`, `a.txt`, `.secret`, `v.mp4` 1000 bajtów), startuje `createPortfolioServer(dir).listen(0)`; testy:
  - `serves index.html at /` → 200, `content-type` zaczyna się od `text/html`.
  - `blocks path traversal` → `/..%2f..%2fREADME.md`, `/%2e%2e/x`, `/%00` dają 400 lub 404, nigdy 200.
  - `404 for dotfiles` → `/.secret`.
  - `range request returns 206 with Content-Range` → `Range: bytes=0-99` daje 206, `content-range: bytes 0-99/1000`, `accept-ranges: bytes`, ciało 100 bajtów.
  - `unsatisfiable range returns 416` → `bytes=5000-`.
  - `rejects POST with 405`.
  - `sets nosniff and CSP` → `x-content-type-options: nosniff`, CSP zawiera `default-src 'self'`, `font-src https://fonts.gstatic.com`, `style-src 'self' https://fonts.googleapis.com`, `media-src 'self'`.

- [ ] **Step 2: Uruchom test, oczekuj FAIL**

Run: `node --test portfolio/test/server.test.mjs`
Expected: FAIL (brak modułu).

- [ ] **Step 3: Zaimplementuj `scripts/serve-portfolio.mjs`**

Reguły: tylko `GET`/`HEAD` (inaczej 405); `decodeURIComponent` w `try` (błąd → 400); katalog → `index.html`; po `path.resolve` ścieżka musi leżeć wewnątrz `rootDir` (inaczej 404); segmenty zaczynające się od `.` → 404; mapa MIME dla `html css js mjs json svg png jpg jpeg webp gif mp4 webm`; `Range` jednozakresowy → 206/416; `Cache-Control: no-cache`; nagłówki z testu. Uruchomienie tylko gdy `import.meta.url` równa się plikowi wejściowemu.

- [ ] **Step 4: Uruchom test, oczekuj PASS**

Run: `node --test portfolio/test/server.test.mjs`
Expected: PASS.

- [ ] **Step 5: Napisz `portfolio/test/design-rules.test.mjs` (czyta `portfolio/css/*.css`)**

  - `no hex or rgb literals outside tokens.css` → w `base.css` i `components.css` brak `#[0-9a-f]{3,8}\b`, `rgb(`, `rgba(`, `hsl(`.
  - `font-weight is 300 or 400 only` → każda deklaracja `font-weight` ∈ {300, 400, `var(--font-weight-light)`, `var(--font-weight-regular)`}.
  - `ember gradient only on .btn-primary` → każda reguła zawierająca `--gradient-ember-cta` ma selektor z `.btn-primary`.
  - `no outset box-shadows` → każda wartość `box-shadow` to `none`, `var(--shadow-subtle-2)`, `var(--shadow-subtle)` albo `var(--shadow-sm)`; `var(--shadow-sm)` tylko w regule z `.btn-frosted`.
  - `no body text in pure white` → `.t-body` i `body` nie używają `--color-cloud-white`.
  Test czyta także `components.css`, gdy plik istnieje (powstaje w Task 3), więc pozostaje poprawny przed jego dodaniem.

- [ ] **Step 6: Napisz `tokens.css` i `base.css`**

`tokens.css`: zmienne z DESIGN.md (kopiuj wartości), `@import` fontu nie tutaj; font ładuje HTML (`<link>` do Google Fonts: DM Sans, wagi 300 i 400). `--font-geomanist` kończy się na `"DM Sans", ui-sans-serif, system-ui, …`.

- [ ] **Step 7: Uruchom testy**

Run: `node --test portfolio/test/`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add scripts/serve-portfolio.mjs portfolio/css portfolio/test
git commit -m "feat(portfolio): serwer deweloperski z Range, tokeny stylu n8n i testy reguł"
```

---

### Task 3: Strona główna z kartami projektów

**Files:**
- Create: `portfolio/index.html`, `portfolio/site.json`
- Create: `portfolio/css/components.css`
- Create: `portfolio/js/main.js`, `portfolio/js/lib/dom.js`, `portfolio/js/lib/load.js`, `portfolio/js/lib/cover.js`
- Create: `portfolio/test/load.test.mjs`, `portfolio/test/no-unsafe-dom.test.mjs`, `portfolio/test/site-placeholders.test.mjs`
- Create: `portfolio/js/blocks/about.js` nie istnieje: sekcja About jest renderowana w `main.js` funkcją `renderAbout(site, container)` (`export` z `portfolio/js/about.js`, nowy plik)

**Interfaces:**
- Consumes: `validateProject`, `validateManifest` z Task 1.
- Produces (`dom.js`): `export function el(tag: string, props?: {class?, text?, attrs?: Record<string,string>}, children?: (Node|string)[]): HTMLElement` (tekst tylko przez `textContent`/`createTextNode`).
- Produces (`load.js`, bez DOM):
  ```js
  export function parseSlug(search: string): string | null;  // z "?p=slug"; null gdy brak lub niezgodny z regexem sluga
  export async function loadProject(fetchJson: (url: string) => Promise<any>, slug: string): Promise<{project: object|null, errors: string[]}>;
  export async function loadProjects(fetchJson: (url: string) => Promise<any>): Promise<{projects: object[], errors: string[]}>;
  ```
  Adresy: `projects/index.json`, `projects/<slug>/project.json`. Walidacja z `fileExists: () => true` (przeglądarka nie sprawdza plików). Projekt niepoprawny lub niepobrany trafia do `errors`, reszta zostaje.
- Produces (`cover.js`): `export function coverFor(project: object, base: string): HTMLElement` — `<img>` z `cover`, a bez niego dekoracyjne SVG z węzłami i liniami Electric Current (to samo motto graficzne co hero).
- Produces (`site.json`, format z Task 1): startowo `{ "name": "Dawid", "headline": "Automation and AI agents that run in production", "about": {"title":"About me","paragraphs":["<placeholder do podmiany przez autora: krótkie bio>"]}, "links": [{"label":"GitHub","url":"https://github.com/DejfW"}] }` bez `cv`, `skills` i `highlights`; autor uzupełnia resztę. Placeholder bio jest wyraźnie oznaczony tekstem `TODO(author): …` i `design-rules`-podobny test `site-placeholders.test.mjs` ostrzega (nie failuje) o `TODO(author)` w plikach `portfolio/`.
- Strona: nav (66px, obramowanie `--color-border-smoke`, logo-tekst, linki „Projects”, „About”, ghost „GitHub” i, gdy jest `cv`, ghost „CV”), hero (display 54px po lewej, dekoracyjny „canvas” SVG z węzłami połączonymi liniami Electric Current wystający za prawą krawędź, animowany przepływ `stroke-dashoffset`; CTA `.btn-primary` „View projects” + `.btn-ghost` „GitHub”), sekcja „Projects” (pierwszy projekt jako szeroki Dark Feature Panel: tekst po lewej, okładka po prawej; kolejne jako Feature Card w siatce 2 kolumn; projekt `planned` jako Glowing Inset Card z badge „Coming soon” i bez linku), sekcja „About” (akapity `about` po lewej, kafelki `highlights` jako Glowing Inset Cards po prawej, grupy `skills` jako piguły, rząd przycisków: GitHub, CV (jeśli jest), pozostałe `links`; sekcje bez danych nie renderują się), stopka z różanym gradientem „Footer Rose” i tymi samymi linkami. Karta shipped/in-progress linkuje do `project.html?p=<slug>`. Komunikat przy pustej liście: „No projects yet”.

- [ ] **Step 1: Napisz `portfolio/test/load.test.mjs`**

  - `parseSlug accepts valid and rejects traversal` → `'?p=meble-automatyzacja'` → `'meble-automatyzacja'`; `'?p=../../etc/passwd'`, `'?p=A_B'`, `'?p=a//b'`, `''`, `'?x=1'` → `null`.
  - `loadProjects returns projects in manifest order` (atrapa `fetchJson` z mapy URL→obiekt).
  - `loadProjects skips broken project and reports it` → manifest z 3 slugami, środkowy rzuca / jest niepoprawny; `projects.length === 2`, `errors.length === 1`, komunikat zawiera slug.
  - `loadProjects with missing manifest returns empty and an error`.
  - `loadProject returns null project for unknown slug` bez rzucania.

- [ ] **Step 2: Napisz `portfolio/test/no-unsafe-dom.test.mjs`**

Rekurencyjnie czyta `portfolio/js/**/*.js` i HTML (`portfolio/*.html`, inline `<script>`); test `no innerHTML, outerHTML, insertAdjacentHTML, document.write, eval` — brak wystąpień.

- [ ] **Step 3: Uruchom testy, oczekuj FAIL**

Run: `node --test portfolio/test/load.test.mjs portfolio/test/no-unsafe-dom.test.mjs`
Expected: `load.test.mjs` FAIL (brak modułu), `no-unsafe-dom` PASS (nie ma jeszcze kodu).

- [ ] **Step 4: Zaimplementuj `load.js`, `dom.js`**

- [ ] **Step 5: Uruchom testy, oczekuj PASS**

Run: `node --test portfolio/test/`
Expected: PASS.

- [ ] **Step 6: Zaimplementuj `components.css`, `index.html`, `main.js`, `cover.js`, `site.json`**

Komponenty z `portfolio/DESIGN.md` → sekcja „Components” (klasy: `.btn-primary`, `.btn-ghost`, `.btn-frosted`, `.pill`, `.badge`, `.card`, `.panel`, `.card-glow`, `.nav`, `.footer`). `main.js` ładuje `site.json` i `loadProjects`, renderuje karty; przy `errors` loguje `console.warn`, a przy pustej liście pokazuje komunikat „No projects yet”. Animacje tylko pod `@media (prefers-reduced-motion: no-preference)`.

- [ ] **Step 7: Zweryfikuj w przeglądarce**

Run: `node scripts/serve-portfolio.mjs` (w tle), otwórz `http://localhost:8090/` w panelu przeglądarki (narzędzia `mcp__Claude_Browser__*`).
Expected: hero + panel projektu meble + karta „Wkrótce” orkiestratora; brak błędów w konsoli (`read_console_messages` z `onlyErrors`); `node --test portfolio/test/` nadal PASS (w tym `design-rules`).

- [ ] **Step 8: Commit**

```bash
git add portfolio
git commit -m "feat(portfolio): strona główna z hero i kartami projektów"
```

---

### Task 4: Strona projektu i bloki tekstowe

**Files:**
- Create: `portfolio/project.html`, `portfolio/js/project.js`
- Create: `portfolio/js/blocks/index.js`, `portfolio/js/blocks/prose.js`, `portfolio/js/blocks/list.js`, `portfolio/js/blocks/table.js`
- Modify: `portfolio/css/components.css`

**Interfaces:**
- Consumes: `loadProject`, `parseSlug` (Task 3), `el` (Task 3).
- Produces: `export const RENDERERS: Record<string, (block: object, ctx: { base: string }) => HTMLElement>` w `blocks/index.js`; `export function renderBlock(block, ctx): HTMLElement` (nieznany typ → element z komunikatem „Nieobsługiwany blok: <typ>” zamiast wyjątku). Każdy plik bloku eksportuje `render(block, ctx)`. `ctx.base` to `projects/<slug>/` (prefiks dla `src`).
- Układ strony: link „← Projects”, nagłówek (display 54px, tagline, badge statusu, rok, rola, piguły tagów, przyciski `links`), rząd `stats` jako Glowing Inset Cards, następnie sekcje bloków na przemian na tle `--surface-void-base` i `--surface-deep-panel` (24px) bez linii rozdzielających. Stan błędu (zły slug, brak projektu, projekt `planned`): panel „Project not found” albo „This project is coming soon” z linkiem do `index.html`. `document.title` = `<title> — <site.name>`.

- [ ] **Step 1: Zaimplementuj `blocks/*.js`, `index.js`, `project.js`, `project.html`, style**

`table` w kontenerze z `overflow-x: auto` (tabela może być szersza niż ekran, strona nie). `list` jako siatka kart z tytułem 20px i tekstem body.

- [ ] **Step 2: Rozszerz testy statyczne**

W `portfolio/test/no-unsafe-dom.test.mjs` nic nie zmieniaj (obejmuje nowe pliki). Uruchom: `node --test portfolio/test/`
Expected: PASS.

- [ ] **Step 3: Zweryfikuj w przeglądarce**

Tymczasowo dodaj do zalążka `meble-automatyzacja` bloki `prose`, `list` i `table` z wartością `<script>alert(1)</script>` w jednym akapicie. Otwórz `http://localhost:8090/project.html?p=meble-automatyzacja`.
Expected: skrypt widoczny jako tekst, brak alertu; `?p=../../etc/passwd`, `?p=nie-ma`, `?p=orkiestrator-agentow` pokazują odpowiednie panele błędu; żądania w `read_network_requests` nie zawierają `..`. Usuń tymczasowy tekst z `<script>`.

- [ ] **Step 4: Commit**

```bash
git add portfolio
git commit -m "feat(portfolio): strona projektu i bloki tekstowe"
```

---

### Task 5: Galeria screenów i nagrań, diagramy, lightbox

**Files:**
- Create: `portfolio/js/blocks/gallery.js`, `portfolio/js/blocks/diagram.js`, `portfolio/js/lib/lightbox.js`
- Modify: `portfolio/js/blocks/index.js`, `portfolio/css/components.css`

**Interfaces:**
- Consumes: `el`, `RENDERERS` (Task 3, 4).
- Produces: `export function openLightbox(opts: { src: string, alt: string, caption?: string }): void` w `lightbox.js` (natywny `<dialog>`, zamknięcie Esc i kliknięciem w tło / przycisk „Close”, fokus wraca na element, który otworzył).
- Galeria: siatka `figure`; obraz `loading="lazy"` z `aspect-ratio: 16/10` i `object-fit: cover`, klik otwiera lightbox; wideo `<video controls preload="metadata" playsinline>` z opcjonalnym `poster`, bez autoodtwarzania; `figcaption` z `caption`. Pusta lista `items` → panel z przerywaną ramką i tekstem „Recordings and screenshots will appear here” (miejsce na materiały autora).
- Diagram: `figure` z obrazem na jasnej tablicy `.canvas-frame` (rysunki SVG z `docs/` mają jasne tło; ramka ma promień 16px i `--color-silver-rail` jako tło), klik otwiera lightbox.

- [ ] **Step 1: Zaimplementuj bloki i lightbox**

- [ ] **Step 2: Zweryfikuj w przeglądarce**

Skopiuj `docs/architecture.svg` do `portfolio/projects/meble-automatyzacja/media/architecture.svg`; w zalążku dodaj blok `diagram` oraz `gallery` z jednym obrazem (ten sam SVG) i jednym pustym wariantem w osobnej sekcji. Uruchom `node scripts/validate-portfolio.mjs`.
Expected: `OK`, ostrzeżenie o pustej galerii; w przeglądarce klik w diagram otwiera lightbox, Esc zamyka i fokus wraca; brak błędów w konsoli; `node --test portfolio/test/` PASS.

- [ ] **Step 3: Commit**

```bash
git add portfolio
git commit -m "feat(portfolio): galeria, diagramy i lightbox"
```

---

### Task 6: Wykres słupkowy i graf zależności

**Files:**
- Create: `portfolio/js/lib/chart-scale.js`, `portfolio/js/lib/graph-layout.js`
- Create: `portfolio/js/blocks/chart.js`, `portfolio/js/blocks/graph.js`
- Create: `portfolio/test/chart-scale.test.mjs`, `portfolio/test/graph-layout.test.mjs`
- Modify: `portfolio/js/blocks/index.js`, `portfolio/css/components.css`

**Interfaces:**
- Produces (`chart-scale.js`, czysta logika):
  ```js
  export function scaleBars(bars: {label: string, value: number}[], opts: { width: number, barHeight: number, gap: number, labelWidth: number }):
    { width: number, height: number, bars: { label: string, value: number, y: number, w: number, h: number }[] };
  ```
  Najdłuższy słupek ma `w = width - labelWidth`; pozostałe proporcjonalnie; gdy `max === 0` wszystkie `w = 0` (bez `NaN`).
- Produces (`graph-layout.js`, czysta logika):
  ```js
  export function layoutGraph(nodes: {id,label,layer,kind?}[], edges: {from,to}[],
    opts: { colWidth: number, rowHeight: number, nodeW: number, nodeH: number, pad: number }):
    { width: number, height: number,
      nodes: { id, label, kind?, x: number, y: number, w: number, h: number }[],
      edges: { from: string, to: string, d: string }[] };
  ```
  Kolumna = `layer`; węzły w kolumnie w kolejności wejściowej, wyśrodkowane pionowo względem najwyższej kolumny; `d` to krzywa sześcienna SVG (`M x1 y1 C …`) od prawej krawędzi środka węzła źródłowego do lewej krawędzi środka docelowego. Nieznany `from`/`to` → `throw new Error('unknown node: <id>')`.
- Render: wykres jako SVG z poziomymi słupkami (wypełnienie Electric Current, etykiety `--color-ash-text`, wartości z `unit`) oraz `<title>` z danymi dla czytników ekranu; graf jako SVG w kontenerze z `overflow-x: auto` i `role="img"` + `aria-label` z listą połączeń; węzły 12px promienia na `--surface-elevated-surface`, linie Electric Current, kolor obrysu zależny od `kind`, animowany przepływ tylko pod `prefers-reduced-motion: no-preference`.

- [ ] **Step 1: Napisz testy**

`chart-scale.test.mjs`:
  - `longest bar fills available width` → dla `[{value:10},{value:5}]`, `width:400, labelWidth:100` → `w` równe 300 i 150.
  - `all zeros yields zero widths without NaN`.
  - `single bar` oraz `empty list` → `bars: []`, `height` skończone.
`graph-layout.test.mjs`:
  - `places nodes in columns by layer` (x rośnie z `layer`, węzły tej samej kolumny mają ten sam x).
  - `edge starts at source right edge and ends at target left edge` (parsuje `d`, porównuje współrzędne).
  - `orphan node without edges still gets a position`.
  - `unknown edge endpoint throws` z komunikatem `unknown node: x`.
  - `tallest column defines height and shorter columns are vertically centered`.

- [ ] **Step 2: Uruchom, oczekuj FAIL**

Run: `node --test portfolio/test/chart-scale.test.mjs portfolio/test/graph-layout.test.mjs`
Expected: FAIL (brak modułów).

- [ ] **Step 3: Zaimplementuj `chart-scale.js` i `graph-layout.js`**

- [ ] **Step 4: Uruchom, oczekuj PASS**

Run: `node --test portfolio/test/`
Expected: PASS.

- [ ] **Step 5: Zaimplementuj `blocks/chart.js`, `blocks/graph.js`, style, rejestrację w `index.js`**

Render grafu łapie wyjątek z `layoutGraph` i pokazuje komunikat zamiast przerywać całą stronę.

- [ ] **Step 6: Zweryfikuj w przeglądarce**

Dodaj do zalążka tymczasowy `chart` (3 słupki) i `graph` (5 węzłów w 3 warstwach); sprawdź wygląd na 1280px i 375px.
Expected: brak poziomego scrolla strony (`document.documentElement.scrollWidth <= window.innerWidth`), graf przewija się w swoim kontenerze, brak błędów w konsoli.

- [ ] **Step 7: Commit**

```bash
git add portfolio
git commit -m "feat(portfolio): wykres słupkowy i graf zależności"
```

---

### Task 7: Treść projektu „Automatyzacja sklepu z meblami”

**Files:**
- Modify: `portfolio/projects/meble-automatyzacja/project.json`
- Create: `portfolio/projects/meble-automatyzacja/media/architecture.svg` (jeśli nie powstał w Task 5)

**Interfaces:**
- Consumes: wszystkie bloki z Task 4–6.

- [ ] **Step 1: Zbierz fakty z repo (nie z pamięci)**

Run:
```bash
ls n8n/workflows | wc -l
ls supabase/migrations | wc -l
ls supabase/tests | wc -l
ls n8n/test | wc -l
ls web/*.html | wc -l
```
Zanotuj wyniki; służą do `stats` i wykresu. Przeczytaj `README.md` (tabele „Problem biznesowy”, „Workflowy n8n”, „Decyzje projektowe”) i `docs/demo-script.md`.

- [ ] **Step 2: Napisz `project.json`**

Zawartość: `status: "shipped"`, `year` z historii gita (`git log --reverse --format=%ad --date=format:%Y | head -1`), `tagline` ≤140 znaków, `tags`: n8n, Supabase, PostgreSQL, Claude, SQL, JavaScript, `links`: repozytorium `https://github.com/DejfW/Portfolio`, `stats` (liczby z kroku 1: workflowy, migracje, pliki testów SQL, kanały), sekcje w kolejności:
  Cały tekst po angielsku (tłumaczenie z polskiego README; nazwa projektu na stronie: „Furniture Workshop Automation”, slug zostaje `meble-automatyzacja`). Dane fikcyjne firm zaznacz jednym zdaniem w „The problem”: „All companies and customers in the demo data are fictional.”
  1. `prose` „The problem” (z README: właściciel małej pracowni mebli na zamówienie).
  2. `table` „What the system does” (kolumny: Pain point, Solution; wiersze z tabeli „Problem biznesowy”).
  3. `diagram` „Architecture” (`media/architecture.svg`, angielski `alt` opisuje przepływ: channels → n8n webhooks → SQL functions → outbox → Slack/e-mail).
  4. `graph` „Dependencies” (warstwy: 0 kanały: form, e-mail, calculator, showroom tablet, status page; 1 workflowy n8n; 2 funkcje SQL / Supabase; 3 outbox i `05-deliver`; 4 Slack, customer e-mail, supplier) — krawędzie zgodne z README.
  5. `table` „n8n workflows” (z tabeli, kolumny: File, Trigger, Job).
  6. `chart` „Test coverage” — słupki z liczbami z kroku 1 (np. pliki testów SQL, testy jednostkowe n8n, skrypty e2e `ls scripts/test-*.sh | wc -l`), `unit` „files”.
  7. `list` „Design decisions” (tytuł + zdanie z README, po angielsku).
  8. `gallery` „Recordings and screenshots” z pustym `items` (miejsce na materiały autora).

- [ ] **Step 3: Zwaliduj i obejrzyj**

Run: `node scripts/validate-portfolio.mjs && node --test portfolio/test/`
Expected: `OK: 2 projects` (ostrzeżenie o pustej galerii jest oczekiwane), testy PASS. Otwórz `project.html?p=meble-automatyzacja` i przejrzyj wszystkie sekcje; liczby na stronie zgadzają się z krokiem 1.

- [ ] **Step 4: Commit**

```bash
git add portfolio
git commit -m "feat(portfolio): treść projektu automatyzacji sklepu z meblami"
```

---

### Task 8: Dopracowanie, dokumentacja i weryfikacja końcowa

**Files:**
- Modify: `portfolio/index.html`, `portfolio/project.html`, `portfolio/css/components.css` (poprawki z weryfikacji)
- Create: `portfolio/README.md`
- Modify: `README.md` (krótka sekcja „Portfolio”)

**Interfaces:**
- Produces: `portfolio/README.md` (po angielsku; repo może być publiczne) z sekcjami „Run locally”, „Edit your profile and CV” (pola `site.json`, jak dodać `assets/cv.pdf` i pole `cv`) oraz poniższymi, w angielskich odpowiednikach: „Uruchomienie” (`node scripts/serve-portfolio.mjs`), „Jak dodać projekt” (4 kroki: skopiuj `projects/_template` do `projects/<slug>`, wypełnij `project.json`, wrzuć pliki do `projects/<slug>/media/`, dopisz slug do `projects/index.json`, uruchom `node scripts/validate-portfolio.mjs`), „Typy bloków” (tabela pól z Task 1), „Jak dodać nagrania i zrzuty” (format pozycji galerii, zalecane `mp4` H.264 ≤ 20 MB, zrzuty `webp`/`png` szerokości 1600 px, zawsze `alt`), „Wdrożenie” (zawartość `portfolio/` to czysta statyka, nadaje się na GitHub Pages / Cloudflare Pages; publikacja jest decyzją autora, plan jej nie wykonuje).

- [ ] **Step 1: Meta i dostępność**

W obu HTML: `<meta name="viewport">`, `<meta name="description">`, `og:title`, `og:description`, `theme-color: #0e0918`, `lang="en"`, link „Skip to content”. Sprawdź kontrast `--color-fog-text` na `--surface-void-base` (wymagane ≥ 4.5:1) — policz ze wzoru WCAG i zapisz wynik w komunikacie commita.

- [ ] **Step 2: Weryfikacja responsywności i ruchu w przeglądarce**

Uruchom serwer; dla `index.html` i `project.html?p=meble-automatyzacja` wykonaj `resize_window` na 375×812, 768×1024, desktop.
Expected: w każdym rozmiarze `document.documentElement.scrollWidth <= window.innerWidth` (sprawdź `javascript_tool`); nagłówek 54px zawija się bez ucinania; nawigacja klawiaturą Tab dociera do wszystkich linków i przycisków z widocznym ringiem; z emulacją `prefers-reduced-motion` brak animowanych elementów; `read_console_messages` bez błędów. Napraw znalezione problemy w CSS i powtórz. Wróć do `preset: "desktop"`.

- [ ] **Step 3: Napisz `portfolio/README.md` i sekcję w root `README.md`**

Sekcja w root README: jedno zdanie + link do `portfolio/README.md` i komenda uruchomienia.

- [ ] **Step 4: Zweryfikuj przepis „Jak dodać projekt” na sucho**

Skopiuj `_template` do `portfolio/projects/probny/`, wypełnij minimalnie, dopisz do manifestu, uruchom `node scripts/validate-portfolio.mjs` i odśwież stronę główną; potem usuń folder i wpis z manifestu.
Expected: karta pojawia się bez zmian w kodzie JS/HTML; po sprzątaniu `git status` pokazuje tylko zamierzone zmiany.

- [ ] **Step 5: Pełny przebieg**

Run: `node --test portfolio/test/ n8n/test/*.test.mjs && node scripts/validate-portfolio.mjs`
Expected: wszystkie testy PASS, `OK: 2 projects`.

- [ ] **Step 6: Commit**

```bash
git add portfolio README.md
git commit -m "docs(portfolio): instrukcja dodawania projektów, dostępność i weryfikacja responsywności"
```

---

## Self-Review

- **Pokrycie wymagań:** graficzna strona z projektami (Task 3), styl n8n z DESIGN.md i jego zakazami wymuszony testem (Task 2), obecny projekt jako jeden z nich (Task 7), miejsce na nagrania, screeny, opisy, wykresy i zależności (bloki `gallery`, `diagram`, `prose`, `chart`, `graph`, Task 4–6), dodawanie kolejnych projektów jednym folderem i wpisem (Task 1, 8; karta „Coming soon” orkiestratora jako wzór), angielska treść strony, sekcja About z linkiem do GitHuba i opcjonalnym CV (Task 1 `validateSite`, Task 3, Task 8).
- **Spójność nazw:** `validateProject`, `validateManifest`, `isSafeRelPath`, `isSafeUrl`, `parseSlug`, `loadProject(s)`, `renderBlock`, `RENDERERS`, `scaleBars`, `layoutGraph`, `openLightbox`, `createPortfolioServer`, `el`, `coverFor` — każda zdefiniowana raz w bloku Interfaces i używana tak samo później.
- **Do uzupełnienia przez autora (poza planem):** nazwisko, nagłówek, bio, umiejętności, `highlights`, e-mail w `portfolio/site.json`, plik `portfolio/assets/cv.pdf` + pole `cv`, nagrania i zrzuty ekranu oraz opisy dla galerii, treść drugiego projektu, decyzja o publikacji.
