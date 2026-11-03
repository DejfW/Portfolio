# Salony stacjonarne, realistyczny seed i omnikanałowość — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Dodać do systemu zamówienia z salonów stacjonarnych (`web/showroom.html`, źródło `'showroom'`), urealnić seed pod asortyment stolarski i uporządkować numerację migracji w planie sprintu.

**Architecture:** Wszystko, co decyduje (walidacja salonu, wycena, idempotencja, przypisanie handlowca), jest w funkcjach SQL. Salon jest identyfikowany kodem z tabeli `showrooms`, a nazwa salonu i e-mail handlowca pochodzą z bazy, nigdy od tabletu. Zamówienie z salonu przechodzi tę samą ścieżkę wyceny co kalkulator (wspólna funkcja wewnętrzna `_place_order`). n8n (workflow 13) tylko wystawia webhook i kolejkuje maile.

**Tech Stack:** Supabase (Postgres 15, RPC), n8n 2.45.7 (generowany przez `n8n/build.mjs`), statyczny HTML/JS serwowany przez `scripts/serve-web.mjs`, testy SQL (`scripts/test-sql.sh`) i bash (`scripts/test-*.sh`).

**Spec:** `docs/superpowers/specs/2026-11-03-stolarnia-kontekst.md` (Task 11, Step 0 zapisuje do niego instrukcję kontekstową z rozmowy: kontekst branżowy, guardrails, seed i `orders`, tabela MVP vs v2, zakres) oraz plan sprintu `docs/superpowers/plans/2026-11-02-meble-automatyzacja.md`.

## Global Constraints

- `orders.source in ('form','email','showroom')`. Nowe kolumny `orders`: `showroom_name text`, `salesperson_email text`, `customer_name text`.
- Kwoty `numeric(12,2)`; zaokrąglenie per pozycja, nagłówek to suma pozycji (bez zmian, `_quote_lines`).
- Błędy walidacji wyceny (`INVALID_SPEC`, `INVALID_QTY`, `INCOMPLETE_PRODUCT`, `NO_PRICE`, `NO_ITEMS`) dają `needs_review` albo `needs_info`.
- Każde zamówienie ma unikalne `external_id` (Message-ID, UUID formularza albo klucz salonu); ponowienie niczego nie duplikuje.
- Stawka robocizny 120 PLN/h, marża 25%, odpad 15%, cena hurtowni ważna 30 dni (bez zmian, tabela `settings`).
- Treść od klienta nigdy nie trafia do stringa komendy powłoki (base64 przez stdin do `scripts/llm.sh`). Showroom nie używa LLM, ale ta zasada obowiązuje każdy nowy węzeł Execute Command.
- Dane demo fikcyjne; adresy tylko w domenie `example.com`.
- Seed używa asortymentu stolarskiego: płyty (`m2`) Płyta laminowana Biała Korpusowa 18 mm, Dąb Halifax Naturalny 18 mm (Egger), MDF Lakierowany Mat 18 mm; okucia (`szt`) Zawias Blum Clip Top z cichym domykiem, Prowadnica Blum Tandembox 50 cm; obrzeże (`mb`) Obrzeże ABS 2 mm.
- Wycena istniejących produktów nie może się zmienić: `estimate_quote`/`_quote_lines` dla każdego z 8 produktów katalogowych (1 szt.) daje po zmianie nazw dokładnie te same `total` co przed nią. Wartości zapisuje Task 11, Step 1 z działającej bazy, a nie z pamięci.
- Salon uwierzytelnia się tokenem (`showrooms.access_token`), a nie samym kodem. Klient wyraża zgodę na kontakt (`orders.consent_at`), a bez niej salon nie przyjmuje zamówienia.
- Zamówienie z salonu ma zawsze `parsed = {"source":"showroom"}`, żeby sweeper mógł naprawić brakujące powiadomienia po awarii.
- Dokumentacja (README, `demo-script.md`) jest aktualizowana w ostatnim kroku każdego taska, a nie na końcu.

## Review Focus

1. Tablet salonowy wysyła to samo zamówienie dwa razy (podwójne dotknięcie): jedno zamówienie i jeden mail do handlowca. Test: Task 12, `test_showroom_idempotent`.
2. Nieznany lub wyłączony kod salonu: błąd `UNKNOWN_SHOWROOM`, zamówienie nie powstaje. Test: Task 12, `test_showroom_unknown_code`.
3. Klient podszywa się pod handlowca: pola `salesperson_email` i `showroom_name` w żądaniu są ignorowane, wartości biorą się z `showrooms`. Test: Task 12, `test_showroom_ignores_client_salesperson`.
4. Lead bez pozycji (klient tylko obejrzał próbki i zostawił kontakt) nie jest wyceną 0 zł, tylko `needs_review` z notatką dla handlowca; pusta notatka i brak pozycji to błąd. Test: Task 12, `test_showroom_lead_without_items`.
5. Imię klienta ze znakami nowej linii lub 10 000 znaków nie psuje maila ani nagłówka: zostaje obcięte do 120 znaków, bez znaków sterujących, i trafia tylko do treści maila. Test: Task 12, `test_showroom_customer_name_sanitized`.

6. Znany kod salonu bez tokenu albo ze złym tokenem: `UNAUTHORIZED`, zamówienie nie powstaje. Test: Task 12, `test_showroom_wrong_token_rejected`.
7. Awaria n8n po zapisie zamówienia z salonu, przed kolejkowaniem maili: sweeper odtwarza `showroom_lead` (także dla leada bez pozycji). Test: Task 12, `test_showroom_recovered_by_sweeper`.
8. Brak zgody klienta: błąd `NO_CONSENT`, zamówienie nie powstaje. Test: Task 12, `test_showroom_requires_consent`.

---

### Task 11: Realistyczny seed i schemat omnikanałowy (migracja 015)

**Files:**
- Create: `docs/superpowers/specs/2026-11-03-stolarnia-kontekst.md`, `supabase/migrations/015_omnichannel.sql`
- Modify: `supabase/seed.sql`, `data/suppliers/*.csv`, `data/suppliers-test/mieszany.csv`, `scripts/test-stock.sh`, `scripts/test-tasks.sh`, `n8n/test/stock.test.mjs`
- Test: `supabase/tests/013_omnichannel_test.sql`

**Interfaces:**
- Produces: `orders.source` check rozszerzony o `'showroom'`; kolumny `orders.showroom_name`, `orders.salesperson_email`, `orders.customer_name` (wszystkie nullable).
- Produces: kolumna `orders.consent_at timestamptz` (nullable).
- Produces: tabela `showrooms(code text primary key check (code ~ '^[a-z0-9-]{3,40}$'), name text not null, salesperson_email text not null, access_token text not null unique default encode(gen_random_bytes(24), 'hex'), active boolean not null default true)`; RLS włączone bez polityk; seed: `warszawa-mokotow`, `krakow-kazimierz`, `gdansk-wrzeszcz` (e-maile `@example.com`).
- Produces: nazwy materiałów według tabeli niżej. Migracja robi `update materials set name = <nowa> where name = <stara>`, żeby baza w chmurze (stan 012–014) dostała zmianę bez resetu; na świeżej bazie jest to no-op, bo `seed.sql` używa już nowych nazw.

| Stara nazwa | Nowa nazwa |
|---|---|
| `Płyta MDF 18 mm biała` | `Płyta laminowana Biała Korpusowa 18 mm` |
| `Płyta dębowa 18 mm` | `Dąb Halifax Naturalny 18 mm (Egger)` |
| `Zawias z cichym domykiem` | `Zawias Blum Clip Top z cichym domykiem` |
| `Prowadnica szuflady 50 cm` | `Prowadnica Blum Tandembox 50 cm` |

Nowe materiały w seedzie: `MDF Lakierowany Mat 18 mm` (`m2`, stock 20, min 8, `custom_ok`, ceny u dwóch hurtowni) i `Obrzeże ABS 2 mm` (`mb`, stock 400, min 150, ceny u dwóch hurtowni, bez BOM i bez `custom_ok`, bo wycena krawędzi to zakres v2).

- [ ] **Step 0: Zapisz specyfikację** (instrukcję kontekstową z rozmowy 2026-11-03) w `docs/superpowers/specs/2026-11-03-stolarnia-kontekst.md`, popraw w niej „100% chroni przed command injection” na „eliminuje wstrzyknięcie do powłoki (prompt injection to osobne ryzyko)” i literówkę „Jedyny źródło”.
- [ ] **Step 1: Zapisz wartości bazowe i napisz test `013_omnichannel_test.sql`.** Na działającej, jeszcze niezmienionej bazie: `select p.name, (_quote_lines(jsonb_build_array(jsonb_build_object('product_id', p.id, 'qty', 1)))->>'total') from products p order by p.name;` i wklej 8 wartości do testu jako literały. Testy: `test_source_showroom_allowed` (insert zamówienia z `source='showroom'` przechodzi, `source='fax'` rzuca naruszenie check), `test_showrooms_seeded` (3 aktywne salony), `test_material_names_realistic` (istnieją wszystkie nazwy z Global Constraints), `test_quote_unchanged_after_rename` (`_quote_lines` dla każdego z 8 produktów 1 szt. daje `total` równy wartościom zapisanym w Step 1), `test_obrzeze_not_custom_ok` (`custom_ok = false`, więc nie pojawia się w `catalog_for_calculator()`).
- [ ] **Step 2: Uruchom `scripts/test-sql.sh supabase/tests/013_omnichannel_test.sql`.** Expected: FAIL (brak tabeli `showrooms`).
- [ ] **Step 3: Napisz migrację 015 i zaktualizuj `seed.sql`** według Interfaces. Zmień nazwy we wszystkich miejscach znalezionych przez `grep -rln "Płyta dębowa 18 mm\|Zawias z cichym\|Prowadnica szuflady 50\|Płyta MDF 18 mm" . --exclude-dir=tmp --exclude-dir=.git --exclude-dir=node_modules` (seed, trzy CSV hurtowni, `mieszany.csv`, dwa skrypty testowe, `stock.test.mjs`); dodaj do CSV wiersze nowych materiałów.
- [ ] **Step 4: Uruchom pełny zestaw:** `supabase db reset && scripts/test-sql.sh && node --test n8n/test/*.test.mjs`, potem po starcie n8n (`ALLOW_LLM_MOCK=1`) `scripts/test-stock.sh`, `scripts/test-tasks.sh`, `scripts/test-calculator.sh`. Expected: wszystko przechodzi, w tym stare testy 001–012 bez zmian asercji kwot.
- [ ] **Step 5: Zaktualizuj README** (lista migracji 001–015, nazwy materiałów w opisie demo) i **commit** `feat: omnichannel orders schema, showrooms and realistic joinery seed`.

### Task 12: Zamówienie z salonu — RPC (migracja 016)

**Files:**
- Create: `supabase/migrations/016_showroom.sql`
- Test: `supabase/tests/014_showroom_test.sql`

**Interfaces:**
- Consumes: `showrooms` (Task 11), `_calculator_quote(p_items jsonb)`, `upsert_order(p jsonb) returns uuid`, `estimate_quote(uuid)`, `enqueue_email(order_id, kind, to, subject, body)`.
- Produces: `_place_order(p jsonb, p_source text) returns jsonb` — ciało dzisiejszego `calculator_order` (walidacja `external_id` i e-maila, wycena po stronie serwera, blokada wiersza, `estimate_quote` tylko przy pierwszym wywołaniu) z parametrem źródła. `calculator_order(p jsonb)` zostaje z tą samą sygnaturą i wywołuje `_place_order(p, 'form')`; testy `012_calculator_order_test.sql` nie mogą wymagać zmian.
- Produces: `orders_missing_notifications` rozszerzone: dla `source = 'showroom'` zamówienie `quoted` wymaga także maila `showroom_lead`, a `needs_review` wymaga `showroom_lead` zamiast `owner_alert`.
- Produces: `showroom_info(p_code text) returns jsonb` → `{"name": "..."}` albo `{}` dla nieznanego lub wyłączonego kodu. Nie zwraca e-maila handlowca.
- Produces: `showroom_order(p jsonb) returns jsonb`. Wejście: `{external_id, showroom_code, access_token, consent, customer_name, customer_email, items?, notes?}`. Wyjście: `{order_id, created, status}` albo `{error}`. Błędy poza tymi z `_place_order`: `UNKNOWN_SHOWROOM`, `UNAUTHORIZED` (zły `access_token`, porównanie stałoczasowe nie jest wymagane, ale komunikat taki sam jak przy nieznanym kodzie na poziomie HTTP), `NO_CONSENT` (`consent` różne od `true`), `EMPTY_LEAD` (brak pozycji i pusta notatka), `INVALID_NAME` (puste imię). Z pozycjami idzie ścieżką `_place_order(p, 'showroom')`. Bez pozycji powstaje zamówienie `kind='catalog'`, `status='needs_review'`, `raw_text` z notatką, bez wyceny. W obu ścieżkach `parsed = {"source":"showroom"}` i `consent_at = now()`. Przy `created = true` ustawia `showroom_name` i `salesperson_email` z `showrooms` oraz `customer_name` (obcięte do 120 znaków, znaki sterujące zamienione na spację).
- Produces: `notification_context` rozszerzone o klucze `showroom_name`, `salesperson_email`, `customer_name`; `email_outbox.kind` rozszerzone o `'showroom_lead'`.
- Grant `execute` tylko dla `service_role`, `set search_path = public, pg_temp`.

- [ ] **Step 1: Napisz testy `014_showroom_test.sql`:** `test_showroom_idempotent` (dwa wywołania z tym samym `external_id`: `created` true, potem false, jedno zamówienie), `test_showroom_unknown_code` (`UNKNOWN_SHOWROOM`, brak wiersza w `orders`), `test_showroom_ignores_client_salesperson` (żądanie z `salesperson_email='hacker@evil.example'` kończy z adresem z `showrooms`), `test_showroom_lead_without_items` (status `needs_review`, `quote is null`; z pustą notatką `EMPTY_LEAD`), `test_showroom_customer_name_sanitized` (imię `E'Jan\r\nBcc: x@y.z'` i 10 000 znaków zapisane jako ≤ 120 znaków bez `\r\n`), `test_showroom_quote_matches_calculator` (te same pozycje dają ten sam `total` co `calculator_order`), `test_showroom_info_hides_email`, `test_showroom_wrong_token_rejected`, `test_showroom_requires_consent`, `test_showroom_recovered_by_sweeper` (zamówienie sprzed 3 minut bez maili jest w `orders_missing_notifications()`, po `enqueue_email(..., 'showroom_lead', ...)` znika; dotyczy też leada bez pozycji).
- [ ] **Step 2: Uruchom `scripts/test-sql.sh supabase/tests/014_showroom_test.sql`.** Expected: FAIL (brak funkcji).
- [ ] **Step 3: Zaimplementuj migrację 016** według Interfaces: najpierw refaktor do `_place_order` i zielone `012`, potem `showroom_*`.
- [ ] **Step 4: Uruchom `scripts/test-sql.sh`.** Expected: wszystkie pliki OK (stary `012` bez zmian).
- [ ] **Step 5: Zaktualizuj README** (lista migracji 001–016, opis kanału salonowego) i **commit** `feat: showroom orders with server-side salon and salesperson`.

### Task 13: Workflow 13, `web/showroom.html` i test end-to-end

**Files:**
- Create: `n8n/workflows/13-showroom.json` (generowany: dodaj `buildShowroom()` w `n8n/build.mjs`), `web/showroom.html`, `scripts/test-showroom.sh`
- Modify: `n8n/code/compose-emails.js` (mail `showroom_lead` do handlowca), `n8n/test/normalize-compose.test.mjs`, `scripts/serve-web.mjs` (bez zmian, jeśli CSP wystarcza; sprawdź)

**Interfaces:**
- Consumes: `showroom_info`, `showroom_order`, `notification_context`, `quote_preview`, `catalog_for_calculator` (workflow 06).
- Produces, webhooki z CORS `*` (jak w 06): `GET /webhook/showroom-info?code=` → `{name}` albo 404; token przekazywany w nagłówku `X-Showroom-Token` (webhook `showroom-order`), a tablet czyta go z adresu `showroom.html?salon=<kod>#<token>` (fragment po `#` nie trafia do logów serwera); `POST /webhook/showroom-order` → 200 `{order_id, created, status}` albo 422 `{error}`. Przepływ jak w 06: Config → RPC → IF error → 422/200 → Created? → Context → Compose emails → Queue email.
- `compose-emails.js` dla `source = 'showroom'`: mail `customer_quote` do klienta (jak dziś), a dodatkowo `showroom_lead` do `salesperson_email` z imieniem klienta, nazwą salonu, pozycjami i notatką, wyłącznie w treści (imię nigdy w temacie). Lead bez wyceny wysyła tylko `showroom_lead`. Dla `source = 'showroom'` nie wysyłamy `owner_alert` z tekstem „Automat nie wycenił…”; treść `showroom_lead` zawiera powód (`needs_review`: „klient zostawił kontakt bez pozycji”).
- `web/showroom.html`: adres `showroom.html?salon=<kod>`; nazwa salonu z `showroom-info` w nagłówku (przy 404 komunikat „Nieprawidłowy link salonu” i zablokowany formularz); pola: imię, e-mail, wymagany checkbox zgody na kontakt z krótkim tekstem (bez zgody przycisk wysyłki nieaktywny), wybór produktów katalogowych z ilością, notatka; wycena na żywo z `/quote-preview` (debounce 350 ms, licznik `seq` jak w `index.html`); przyciski i pola min. 48 px; klucz idempotencji `showroom:<kod>:` + 16 znaków SHA-256 treści; po sukcesie ekran „Dziękujemy” i reset formularza po 10 s; żadnych danych klienta w `localStorage`.

- [ ] **Step 1: Napisz `scripts/test-showroom.sh`** (wzór: `test-calculator.sh`; wymaga n8n z `ALLOW_LLM_MOCK=1`): `showroom_info_ok` (nazwa salonu bez klucza `salesperson_email`), `showroom_info_unknown_404`, `showroom_order_creates_and_queues` (zamówienie `source='showroom'`, w `email_outbox` dokładnie jeden `customer_quote` i jeden `showroom_lead` na adres handlowca), `showroom_order_twice_one_order` (ten sam klucz dwa razy: jedno zamówienie, brak drugiego maila), `showroom_unknown_code_422`, `showroom_lead_only_notifies_salesperson`, `showroom_preflight_cors` (OPTIONS zwraca nagłówki CORS), `showroom_wrong_token_422`, `showroom_no_consent_422`.
- [ ] **Step 2: Uruchom.** Expected: FAIL (404 na webhookach).
- [ ] **Step 3: Zaimplementuj** `buildShowroom()` i zmianę w `compose-emails.js`, dodaj test jednostkowy „showroom_lead nie ma imienia klienta w temacie”, napisz `web/showroom.html`. Potem `scripts/n8n.sh sync`, restart w trybie testowym i odczekaj ok. 25 s.
- [ ] **Step 4: Uruchom** `scripts/test-showroom.sh`, `scripts/test-calculator.sh`, `scripts/test-sql.sh`, `node --test n8n/test/*.test.mjs`. Potem w przeglądarce `http://localhost:8080/showroom.html?salon=warszawa-mokotow` w widoku 768×1024: wycena zmienia się na żywo, złożenie zamówienia pokazuje „Dziękujemy”, a z kodem `zly-kod` formularz jest zablokowany. Expected: wszystko przechodzi.
- [ ] **Step 5: Dopisz `13-showroom` do tabeli workflowów w README i krok „lead z salonu” do `docs/demo-script.md`** (całość nadal w 3 minutach), potem **commit** `feat: showroom tablet form and workflow 13`.

### Task 14: Synchronizacja numeracji w planie sprintu

**Files:**
- Modify: `docs/superpowers/plans/2026-11-02-meble-automatyzacja.md`

**Interfaces:**
- Produces: spójna numeracja, na którą powołują się Taski 7–10: migracje `017_purchasing.sql` (Task 7), `018_followup.sql` (Task 8), `019_inbox.sql` (Task 9), `020_status.sql` (Task 10); testy SQL `015_purchasing_test.sql`, `016_followup_test.sql`, `017_status_test.sql`. Nazwy workflowów według specyfikacji (podane dwukrotnie przez autora): `08-purchase-orders`, `09-quote-followup`, `10-status-notify`, `12-review-request`; triage, którego spec nie numeruje, dostaje wolny numer `11-inbox-triage`; salon to `13-showroom`. Krok 1 przemianowuje w starym planie `10-inbox-triage` → `11-inbox-triage` i `11-status-notify` → `10-status-notify`.

- [ ] **Step 1: W planie sprintu** popraw numery migracji i testów w Taskach 7–10 według Interfaces, dopisz do Global Constraints wartości `source` z tego planu, dopisz Taski 11–14 do spisu i zmień kolejność w „Kolejność, gdy zabraknie czasu” na: 11 → 12 → 7 → 8 → 13 → 6 → 9 → 10 (RPC salonu jest małe, a tablet z workflowem 13 przesuwamy, jeśli zabraknie czasu na Taski 7–8).
- [ ] **Step 2: Sprawdź** `grep -n "00[5-9]_\|01[0-1]_" docs/superpowers/plans/2026-11-02-meble-automatyzacja.md` — w Taskach 7–10 nie mogą zostać numery kolidujące z istniejącymi migracjami 001–016. Expected: brak kolizji.
- [ ] **Step 3: Commit** `docs: sync sprint plan numbering`.

---

## Pokrycie specyfikacji (kontekst z 2026-11-03, wersja zbiorcza)

| Wymaganie specyfikacji | Gdzie |
|---|---|
| Task 1–2, 4–6 (schemat, magazyn, zadania, kalkulator, raport, README) | Wykonane; Task 11 zmienia tylko nazwy materiałów i dodaje obrzeże |
| Task 3: `/webhook/order` i źródło `showroom` | **Decyzja:** salon używa ustrukturyzowanej ścieżki `/webhook/showroom-order` (bez parsera AI), bo tablet wysyła gotowe pozycje, a `/webhook/order` zostaje dla tekstu swobodnego z formularza i maila. Źródło `showroom` jest w `orders.source` (Task 11). Jeśli salon ma też wysyłać tekst swobodny, dopisz osobny task: `/webhook/order` z `source='showroom'` wymagałby kodu salonu i walidacji w `intake_receive` |
| `web/showroom.html`, `showroom_name`, `salesperson_email`, `customer_name` | Task 11–13 |
| Seed stolarski, obrzeże `mb` | Task 11 |
| Task 7–10 (auto-PO, follow-up, triage, statusy) | Plan sprintu, numeracja w Task 14 |
| Guardrails: idempotencja, base64/stdin, grosze, `needs_review`/`needs_info` | Global Constraints i Review Focus powyżej |

## Poza zakresem (v2, zgodnie z tabelą MVP vs produkcja)

Widełki cenowe ±10% w `quote_preview`, `generate_cutlist()` z eksportem CSV, zaokrąglanie zamówień płyt do pełnych arkuszy i `lead_time_days`, bramka `deposit_paid_at`, lista załadunkowa z BOM, blokada prośby o opinię przy otwartej reklamacji oraz obrzeże w BOM produktów. Opisz je w README w sekcji „Co dalej”.
