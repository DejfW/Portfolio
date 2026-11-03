# Meble na zamówienie — system automatyzacji (sprint 2–6.11.2026) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Projekt portfolio: system dla sklepu z meblami na zamówienie, który przyjmuje zamówienia (formularz i e-mail), parsuje je z pomocą AI, robi wstępny kosztorys, rezerwuje materiały przy zlecaniu zadań zespołowi, porównuje ceny hurtowni, daje klientowi kalkulator wyceny i wysyła raport bestsellerów.

**Architecture:** Supabase (Postgres) jest jedynym źródłem prawdy. Cała logika, która musi być spójna (wycena, rezerwacja magazynu, najlepsza cena, bestsellery), siedzi w funkcjach SQL wywoływanych przez RPC, bo transakcje rozwiązują problem równoległych zleceń. n8n tylko orkiestruje: wyzwalacze, wywołania LLM (lokalne `agy` przez jeden wspólny sub-workflow), RPC do Supabase i powiadomienia. Kalkulator dla klienta to jedna statyczna strona HTML wołająca webhook n8n.

**Tech Stack:** Supabase (Postgres 15, RPC), n8n uruchamiane lokalnie przez `npx n8n` (nie Docker, bo kontener nie widzi `agy`), Antigravity CLI (`agy --print`, model `gemini-3.8-flash-medium`) do parsowania i tekstów, Gmail (IMAP) jako skrzynka zamówień, Slack lub e-mail do powiadomień zespołu, statyczny HTML z Tailwind CDN.

**Spec:** Brak osobnego dokumentu. Zakres ustalono w rozmowie 2026-11-02: n8n zamiast Zapiera, kod pisze Claude, sprint do końca tygodnia, priorytet mają 3 filary (zamówienia, magazyn i zadania, kalkulator z raportem). Dodatki (decyzja z 2026-11-02, w miejsce social mediów): zamówienia do hurtowni, follow-up wycen, triage skrzynki AI, statusy i opinie (Task 7–10). Social media przechodzą do v2.

## Global Constraints

- Waluta PLN, kwoty `numeric(12,2)`. Zaokrąglenie do 0,01 następuje per pozycja wyceny, a nagłówek to suma zaokrąglonych pozycji, więc rozbicie zawsze sumuje się do `total` co do grosza (zmiana po recenzji Codex).
- Walidacja wejścia wyceny jest w bazie (`_quote_lines`), nie tylko w n8n: wymiary mebla na wymiar 20–300 cm, ilość to liczba całkowita 1–1000, produkt musi mieć BOM i `labor_hours > 0`. Błędy: `INVALID_SPEC`, `INVALID_QTY`, `INCOMPLETE_PRODUCT`, `NO_PRICE`, `NO_ITEMS`; zamówienie dostaje wtedy `needs_review`.
- Statusy zamówienia zmienia tylko system: `upsert_order` przyjmuje wyłącznie `new`, `needs_info`, `needs_review`, a `estimate_quote` odrzuca zamówienie po przejściu do realizacji (`ORDER_LOCKED`).
- Stawka robocizny: 120 PLN/h. Marża: 25% (od materiałów i robocizny). Naddatek na odpad: 15%. To założenia demo, trzymane w tabeli `settings`, a nie w kodzie.
- Cena hurtowni jest ważna 30 dni od `updated_at`. Ceny `<= 0` są ignorowane.
- Stan magazynowy nigdy nie spada poniżej 0. Dostępne = `stock - reserved`.
- Każde zamówienie ma unikalne `external_id` (Message-ID z maila albo UUID z formularza), więc ponowne przetworzenie niczego nie duplikuje.
- Wynik LLM zawsze przechodzi walidację. Niepoprawny JSON albo nieznany materiał daje status `needs_review`, a nie wycenę.
- Treść maila ani formularza nigdy nie trafia do stringa komendy powłoki. Prompt jest kodowany w base64 (znaki `[A-Za-z0-9+/=]`) i przekazywany do `scripts/llm.sh` przez stdin, więc do powłoki nie trafia nic, co pochodzi od klienta. Chroni to przed wstrzyknięciem komendy przez klienta.
- Sekrety (Supabase service key, Gmail) tylko w credentials n8n. Nigdy w eksportowanych JSON-ach workflow ani w repo.
- Dane demo są fikcyjne: 3 hurtownie, ok. 12 materiałów, 8 produktów katalogowych, 60 historycznych zamówień.

## Review Focus

1. Mail bez wymiarów lub materiału ma dostać status `needs_info` i automatyczną prośbę o doprecyzowanie, a nie wycenę 0 zł. Test: Task 3, `parse_incomplete_email`.
2. Dwa zadania zlecone naraz na ten sam materiał: drugie ma być odrzucone z `INSUFFICIENT_STOCK`, a stan nie może zejść poniżej zera. Test: Task 2, `test_concurrent_reservation`.
3. Ten sam mail przetworzony dwa razy (restart n8n) ma dać jedno zamówienie. Test: Task 1, `test_external_id_idempotent`.
4. Hurtownia bez aktualnej ceny materiału jest pomijana. Brak jakiejkolwiek ceny daje alert, a nie wycenę z ceną 0. Test: Task 2, `test_best_price_stale_ignored`.
5. LLM zwraca śmieci lub nieznany materiał: status `needs_review`, workflow się nie wysypuje. Test: Task 3, `parse_garbage_llm_output`.
6. Triage nie może zgubić zamówienia. Niepewna klasyfikacja (confidence < 0,7) albo błąd LLM kieruje mail do intake, a nie do spamu. Spam dostaje tylko etykietę i nigdy nie jest usuwany. Test: Task 9, `triage_uncertain_goes_to_intake`.

---

### Task 1: Schemat bazy, seed i funkcja wyceny (pon.)

**Files:**
- Create: `supabase/migrations/001_schema.sql`
- Create: `supabase/migrations/002_quote.sql`
- Create: `supabase/seed.sql`
- Test: `supabase/tests/001_quote_test.sql`

**Interfaces:**
- Produces, tabele: `settings(key text pk, value numeric)`, `materials(id uuid, name, unit, stock numeric, reserved numeric, min_stock numeric)`, `products(id uuid, name, base_price numeric, labor_hours numeric)`, `product_materials(product_id, material_id, qty)`, `suppliers(id, name, email)`, `supplier_prices(supplier_id, material_id, price, updated_at)`, `orders(id uuid, external_id text unique, source text check in ('form','email'), customer_email, kind check in ('catalog','custom'), status check in ('new','needs_info','needs_review','quoted','approved','in_progress','done','lost'), raw_text, parsed jsonb, quote jsonb, quoted_at timestamptz, followups_sent int default 0, public_token uuid unique default gen_random_uuid(), review_requested_at timestamptz, created_at)`. Kolumny `lost`, `quoted_at`, `followups_sent`, `public_token` i `review_requested_at` są od razu w schemacie dla Task 8 i 10, żeby nie zmieniać constraintów później, `order_items(id, order_id, product_id null, custom_spec jsonb null, qty int)`, `tasks(id, order_id, assignee, status check in ('todo','doing','done'), created_at)`, `stock_movements(id, material_id, task_id, qty, kind check in ('reserve','consume','release','receive'), created_at)`. `estimate_quote` ustawia `quoted_at = now()`.
- Produces: `upsert_order(p jsonb) returns uuid`. Wstawia zamówienie i pozycje. Przy istniejącym `external_id` zwraca istniejące id bez zmian.
- Produces: `estimate_quote(p_order_id uuid) returns jsonb` w kształcie `{lines:[{label, materials_cost, labor_cost}], materials_cost, labor_cost, margin, total}`. Zapisuje wynik w `orders.quote` i ustawia status `quoted`.
- Custom spec: `{width_cm, height_cm, depth_cm, material_id}`. Powierzchnia płyty w m² = `(2*w*d + 2*h*d + w*h)/10000 * 1.15`, robocizna w h = `4 + 2 * m²`, koszt materiału = m² × `best_price` (Task 2; w Task 1 tymczasowo najniższa cena z `supplier_prices`).

- [ ] **Step 1: Napisz testy** w `001_quote_test.sql` jako bloki `do $$ ... assert ... $$`: `test_catalog_quote` (produkt z BOM: 2 m² płyty po 100 PLN i 3 h, czyli materiały 200, robocizna 360, marża 140, total 700.00), `test_custom_quote` (100×80×40 cm: m² = (8000+6400+8000)/10000×1.15 = 2.576, sprawdź total z dokładnością 0.01), `test_external_id_idempotent` (dwa `upsert_order` z tym samym `external_id` dają to samo id i `count(*) = 1`).
- [ ] **Step 2: Uruchom testy na pustej bazie.** Run: `execute_sql` (Supabase MCP) z treścią pliku testów. Expected: błąd `function upsert_order does not exist`.
- [ ] **Step 3: Zaimplementuj migracje 001 i 002 oraz seed** (dane z Global Constraints; historyczne zamówienia rozłożone na 90 dni z przewagą 2–3 produktów, żeby raport bestsellerów miał co pokazać).
- [ ] **Step 4: Uruchom testy ponownie.** Expected: brak wyjątków.
- [ ] **Step 5: Commit** `feat(db): schema, seed, estimate_quote`.

### Task 2: Magazyn, rezerwacje i najlepsza cena (wt.)

**Files:**
- Create: `supabase/migrations/003_inventory.sql`
- Test: `supabase/tests/002_inventory_test.sql`

**Interfaces:**
- Consumes: tabele z Task 1.
- Produces: `best_price(p_material_id uuid) returns table(supplier_id uuid, supplier_name text, price numeric)`. Jeden wiersz albo zero, z uwzględnieniem reguły 30 dni i ceny > 0. `estimate_quote` przełącza się na tę funkcję, a przy braku ceny ustawia status `needs_review`.
- Produces: `create_task(p_order_id uuid, p_assignee text) returns uuid`. W jednej transakcji, z `select ... for update` na materiałach, liczy zapotrzebowanie z BOM lub custom spec, sprawdza dostępność (`stock - reserved`), zwiększa `reserved`, zapisuje `stock_movements(kind='reserve')` i ustawia status zamówienia `in_progress`. Przy braku materiału: `raise exception 'INSUFFICIENT_STOCK:%', material_name`.
- Produces: `complete_task(p_task_id uuid) returns void`. Rezerwacja zamienia się w zużycie (`stock -= qty`, `reserved -= qty`, ruch `consume`), task i zamówienie dostają status `done`.
- Produces: widok `low_stock` z kolumnami `(material_id, name, available, min_stock, best_supplier, best_price)`.

- [ ] **Step 1: Napisz testy:** `test_create_task_reserves` (reserved rośnie o zapotrzebowanie, jest 1 ruch `reserve`), `test_complete_task_consumes`, `test_insufficient_stock_raises` (wyjątek, a `reserved` bez zmian), `test_concurrent_reservation` (dwa zamówienia, każde potrzebuje 60% stanu: pierwsze przechodzi, drugie rzuca `INSUFFICIENT_STOCK`, `available >= 0`), `test_best_price_stale_ignored` (najtańsza cena sprzed 31 dni jest pomijana, a przy samych przeterminowanych cenach wynik jest pusty).
- [ ] **Step 2: Uruchom testy.** Expected: FAIL, funkcje nie istnieją.
- [ ] **Step 3: Zaimplementuj migrację 003.**
- [ ] **Step 4: Uruchom testy z Task 1 i 2.** Expected: wszystkie przechodzą.
- [ ] **Step 5: Commit** `feat(db): inventory reservations, best_price, low_stock`.

### Task 3: n8n — przyjmowanie zamówień i wycena AI (wt.–śr.)

**Files:**
- Create: `n8n/workflows/01-order-intake.json`
- Create: `n8n/prompts/parse-order.md`
- Create: `n8n/fixtures/` (`email-*.txt` i `llm-*.json`), `n8n/code/*.js` (kod węzłów Code), `n8n/build.mjs` (generuje `workflows/*.json`)
- Create: `supabase/migrations/005_catalog_outbox.sql`, `006_intake.sql`, testy `004_outbox_test.sql`, `005_intake_test.sql`
- Create: `scripts/n8n.sh` (start, import i publikacja przez `npx`), `n8n/workflows/02-intake-sweeper.json` (co 5 min: zgłoszenia niedomknięte po 10 min idą do sprawdzenia, brakujące maile są uzupełniane), `supabase/migrations/007_intake_recovery.sql`, testy w Node `n8n/test/*.test.mjs` (`node --test n8n/test/`)
- Create: `scripts/test-intake.sh`
- Create: `scripts/llm.sh`, `n8n/workflows/00-llm.json` (sub-workflow LLM z sekcji „LLM w workflowach n8n”)

**Interfaces:**
- Consumes: `upsert_order`, `estimate_quote` (Task 1). Produces w bazie: `catalog_for_llm() returns jsonb`, `intake_receive(p jsonb) returns jsonb` (zapis zgłoszenia przed odpowiedzią HTTP; `created=false` dla duplikatu), `intake_complete(p_order_id uuid, p jsonb) returns jsonb` (domknięcie wynikiem AI, `route` = `ok`, `needs_info`, `needs_review`; działa raz), `notification_context(uuid)`, `orders_missing_notifications(int)`, `mark_stuck_intakes(int)` (odzyskiwanie po awarii), tabela `email_outbox` i `enqueue_email(order_id, kind, to, subject, body) returns uuid` (unikalnie po zamówieniu i rodzaju). Maile trafiają do `email_outbox`; faktyczną wysyłkę dopinamy, gdy jest skrzynka (Gmail), do tego czasu da się je sprawdzić w tabeli.
- Produces: webhook `POST /webhook/order` z body `{external_id?, customer_email, message}`. Ta sama ścieżka obsługuje też formularz. Odpowiedź po trwałym zapisie zgłoszenia: `{external_id, status: "processing"}` (lub `"duplicate"`), a reszta biegnie asynchronicznie (LLM potrzebuje 10–30 s). `external_id` jest wymagany. Opcjonalny `INTAKE_TOKEN` wymusza nagłówek `X-Intake-Token` (401). Nagłówek `X-LLM-Mock: <nazwa>` działa tylko przy `ALLOW_LLM_MOCK=1` i tylko dla nazw pasujących do `^[a-z0-9-]+$`. Podmienia wtedy odpowiedź LLM na `n8n/fixtures/llm-<nazwa>.json`.
- Przepływ (w Task 3 samo wejście webhookowe; IMAP Trigger dochodzi z Gmailem w Task 9): Webhook → normalizacja do `{external_id, source, customer_email, raw_text}` → LLM (prompt z listą produktów i materiałów pobraną z bazy; wynik to wyłącznie JSON `{kind, items:[{product_name?|custom_spec?, qty}], missing:[...]}`) → Code node waliduje schemat i mapuje nazwy na id → gałąź: `missing` niepuste daje `needs_info` i mail z prośbą o brakujące dane; błąd walidacji daje `needs_review`; w pozostałych przypadkach `upsert_order` i `estimate_quote` → mail do klienta z wyceną wstępną oraz wiadomość na Slacku dla właściciela z linkiem do zatwierdzenia (`/webhook/approve?order_id=`).

- [ ] **Step 1: Napisz `scripts/test-intake.sh`**, który wysyła każdy fixture curlem z nagłówkiem `X-LLM-Mock`, a potem odpytuje bazę (co 0,5 s, maks. 40 s) o status zamówienia i maile w `email_outbox`: `parse_catalog_email` daje `quoted`, `parse_custom_email` daje `quoted` i `quote.total > 0`, `parse_incomplete_email` daje `needs_info`, `parse_garbage_llm_output` daje `needs_review`. Ten sam fixture wysłany drugi raz nie tworzy drugiego wiersza. `shell_injection_safe`: wiadomość `"; touch /tmp/pwned; echo "` nie tworzy pliku `/tmp/pwned`. Jeden test (`smoke_real_agy`) idzie bez mocka do prawdziwego `agy` i sprawdza tylko, że zamówienie dostało status inny niż `processing`.
- [ ] **Step 2: Uruchom skrypt przy pustym n8n.** Expected: FAIL, 404 na webhooku.
- [ ] **Step 3: Zbuduj workflow** w n8n, wyeksportuj go bez credentials do `01-order-intake.json` i zapisz prompt.
- [ ] **Step 4: Uruchom skrypt.** Expected: 5/5 OK. Ręcznie: wyślij prawdziwy mail na skrzynkę demo i sprawdź, czy wiersz w `orders` ma `source='email'`.
- [ ] **Step 5: Commit** `feat(n8n): order intake with AI parsing and quote`.

### Task 4: n8n — zatwierdzenie, zadania dla zespołu i alerty magazynowe (śr.–czw.)

**Files:**
- Create: `n8n/workflows/02-approve-and-assign.json`
- Create: `n8n/workflows/03-complete-task.json`
- Create: `n8n/workflows/04-stock-and-prices.json`
- Create: `data/suppliers/hurtownia-{a,b,c}.csv` w formacie `material_name,price`
- Create: `scripts/test-tasks.sh`

**Interfaces:**
- Consumes: `create_task`, `complete_task`, `low_stock`, `supplier_prices`.
- Produces: `GET /webhook/approve?order_id=&assignee=` ustawia status `approved`, wywołuje `create_task` i wysyła Slack do wykonawcy. Przy `INSUFFICIENT_STOCK` wysyła do właściciela listę braków z najlepszym dostawcą.
- Produces: `POST /webhook/task-done {task_id}` wywołuje `complete_task`, a potem mail do klienta „zamówienie gotowe”.
- Produces: cron codziennie o 7:00 wczytuje 3 CSV, robi upsert do `supplier_prices` (`updated_at = now()`), czyta `low_stock` i wysyła jedną zbiorczą wiadomość „do zamówienia: materiał, ilość, hurtownia, cena”.

- [ ] **Step 1: Napisz `scripts/test-tasks.sh`:** approve zamówienia z seedu daje `in_progress` i rosnące `reserved` (sprawdzane przez REST), dwa approve na materiał na granicy stanu dają drugą odpowiedź `INSUFFICIENT_STOCK`, task-done zmniejsza `stock`, ręczny run workflow 04 aktualizuje `updated_at` cen i zwraca listę `low_stock`.
- [ ] **Step 2: Uruchom.** Expected: FAIL (404).
- [ ] **Step 3: Zbuduj i wyeksportuj workflowy 02–04.**
- [ ] **Step 4: Uruchom skrypt i skrypt z Task 3.** Expected: wszystko OK.
- [ ] **Step 5: Commit** `feat(n8n): approval, team tasks, stock and price alerts`.

### Task 5: Kalkulator dla klienta i raport bestsellerów (czw.)

**Files:**
- Create: `web/index.html` (kalkulator: wybór produktu albo wymiary i materiał → wycena na żywo → „Zamów” wysyła na `/webhook/order`)
- Create: `supabase/migrations/007_reports.sql`
- Create: `n8n/workflows/05-quote-preview.json`, `n8n/workflows/06-weekly-report.json`
- Test: `supabase/tests/006_reports_test.sql`

**Interfaces:**
- Produces: `quote_preview(p jsonb) returns jsonb`. Ta sama logika co `estimate_quote`, ale bez zapisu. Refaktor: obie funkcje używają wspólnej `_quote_lines(items jsonb)`.
- Produces: `bestsellers(p_days int) returns table(product_id uuid, name text, qty bigint, revenue numeric)`, posortowane malejąco po `qty`. Zamówienia custom liczone są jako „Na wymiar”.
- Produces: `POST /webhook/quote-preview` zwraca wynik `quote_preview`, z CORS dla domeny strony.
- Produces: cron w poniedziałek o 8:00: `bestsellers(7)` i `bestsellers(30)` → LLM pisze 5-zdaniowe podsumowanie z rekomendacją → mail HTML z tabelą.

- [ ] **Step 1: Napisz testy:** `test_preview_matches_estimate` (ten sam input daje identyczny `total` jak `estimate_quote`), `test_preview_does_not_write` (`count(orders)` bez zmian), `test_bestsellers_order` (na seedzie najczęstszy produkt jest pierwszy).
- [ ] **Step 2: Uruchom.** Expected: FAIL.
- [ ] **Step 3: Zaimplementuj migrację 004, workflowy 05–06 i `web/index.html`** (formularz po polsku, walidacja wymiarów 20–300 cm po stronie strony i w SQL, w trakcie liczenia stan „Liczę…”).
- [ ] **Step 4: Uruchom testy SQL. Otwórz `web/index.html` w przeglądarce**, policz wycenę katalogową i custom, złóż zamówienie i sprawdź, czy pojawiło się w `orders` ze statusem `quoted`. Ręcznie odpal workflow 06 i sprawdź, czy mail przyszedł.
- [ ] **Step 5: Commit** `feat: customer calculator and weekly bestseller report`.

### Task 6: Paczka portfolio (pt. po południu; aktualizacja po Task 9–10)

Social media są poza zakresem (pomysł na v2, opisany w README w sekcji „co dalej”).

**Files:**
- Create: `README.md`, `docs/architecture.svg`, `docs/demo-script.md`

- [ ] **Step 1: Najpierw dokończ Task 7 i 8.** README opisuje tylko to, co przechodzi testy.
- [ ] **Step 2: Napisz README:** problem biznesowy, diagram, lista workflowów z wyzwalaczami, decyzje (dlaczego logika jest w SQL, human-in-the-loop, idempotencja), instrukcja uruchomienia w 10 krokach, „co bym dodał w produkcji”.
- [ ] **Step 3: Scenariusz wideo demo (3 min):** mail od klienta → wycena w skrzynce → approve → rezerwacja → brak materiału → szkic zamówienia do najtańszej hurtowni → akceptacja → dostawa zwiększa stan → kalkulator → przypomnienie o wycenie → raport.
- [ ] **Step 4: Pełny przebieg:** wszystkie testy SQL i wszystkie `scripts/test-*.sh`. Expected: wszystko przechodzi.
- [ ] **Step 5: Commit** `docs: README, architecture, demo script`. Po Task 9–10 dopisz je do README i scenariusza demo, potem commit `docs: triage and status tracking`.

### Task 7: Zamówienia do hurtowni, czyli auto-PO (pt. rano)

**Files:**
- Create: `supabase/migrations/008_purchasing.sql`
- Test: `supabase/tests/007_purchasing_test.sql`
- Create: `n8n/workflows/08-purchase-orders.json`, `scripts/test-purchasing.sh`

**Interfaces:**
- Consumes: `low_stock`, `best_price`, `stock_movements` (Task 2), `suppliers.email`.
- Produces, tabele: `purchase_orders(id uuid, supplier_id, status check in ('draft','sent','received','cancelled'), approve_token uuid unique default gen_random_uuid(), created_at, sent_at, received_at)`, `purchase_order_lines(po_id, material_id, qty numeric, unit_price numeric)`.
- Produces: `create_purchase_orders() returns setof uuid`. Dla każdego materiału z `low_stock`, którego nie ma jeszcze w PO `draft` ani `sent`: `qty = ceil(2*min_stock - available)`. Materiały są grupowane po najtańszym dostawcy, jeden szkic PO na dostawcę. Materiał bez aktualnej ceny jest pomijany, a funkcja `low_stock_unpriced()` zwraca listę takich materiałów do alertu.
- Produces: `approve_purchase_order(p_token uuid) returns uuid`. Zmienia status `draft` na `sent` i ustawia `sent_at`. Z innego statusu: `raise exception 'PO_NOT_DRAFT'`.
- Produces: `receive_delivery(p_po_id uuid) returns void`. Tylko ze statusu `sent`, inaczej `raise exception 'PO_NOT_SENT'`. Dla każdej linii `stock += qty` i ruch `kind='receive'`, status `received`.
- Workflow 08: cron codziennie o 7:15 (po workflow 04) → `create_purchase_orders` → dla każdego PO wiadomość do właściciela z tabelą i linkiem `GET /webhook/po-approve?token=` → po akceptacji mail do hurtowni z tabelą pozycji. `GET /webhook/po-received?po_id=` wywołuje `receive_delivery`.

- [ ] **Step 1: Napisz testy:** `test_po_groups_by_cheapest_supplier` (2 materiały z najtańszą ceną u hurtowni A i 1 u B dają 2 PO o poprawnych liniach i `unit_price`), `test_po_idempotent` (drugie wywołanie przy otwartych szkicach zwraca 0 wierszy), `test_po_skips_unpriced` (materiał z samymi przeterminowanymi cenami nie trafia do PO, ale jest w `low_stock_unpriced()`), `test_receive_delivery_increases_stock`, `test_receive_requires_sent` (`receive_delivery` na `draft` rzuca `PO_NOT_SENT`).
- [ ] **Step 2: Uruchom.** Expected: FAIL.
- [ ] **Step 3: Zaimplementuj migrację 005. Równolegle Codex buduje workflow 08** według Interfaces.
- [ ] **Step 4: Uruchom testy SQL i `scripts/test-purchasing.sh`** (ręczny run 08 → approve przez token → po-received → `stock` wzrósł). Expected: OK.
- [ ] **Step 5: Commit** `feat: automatic purchase orders to wholesalers`.

### Task 8: Follow-up wycen (pt. po południu)

**Files:**
- Create: `supabase/migrations/009_followup.sql`
- Test: `supabase/tests/008_followup_test.sql`
- Create: `n8n/workflows/09-quote-followup.json`, `n8n/fixtures/llm-followup.json`, `scripts/test-followup.sh`

**Interfaces:**
- Consumes: `orders.quoted_at`, `orders.followups_sent`, `orders.public_token` (Task 1), sub-workflow `00-llm`.
- Produces: `quotes_due_followup() returns table(order_id uuid, customer_email text, followup_no int, quote jsonb)`. Status `quoted` i: `followups_sent = 0` przy `quoted_at <= now() - 3 days` daje numer 1, a `followups_sent = 1` przy `quoted_at <= now() - 7 days` daje numer 2.
- Produces: `mark_followup_sent(p_order_id uuid, p_no int) returns boolean`. Ustawia `followups_sent = p_no` tylko wtedy, gdy obecna wartość to `p_no - 1`, więc ponowny run niczego nie dubluje.
- Produces: `mark_lost_quotes(p_days int default 14) returns setof uuid`. Zmienia `quoted` na `lost`, gdy `quoted_at <= now() - p_days`.
- Produces: tabela `lost_reasons(order_id, reason check in ('price','time','other_offer','other'), created_at)` i `record_lost_reason(p_token uuid, p_reason text) returns void`, wołana z `GET /webhook/lost-reason?token=&r=`. Jedno kliknięcie w mailu wystarczy.
- Workflow 09: cron codziennie o 9:00 → `quotes_due_followup` → `00-llm` pisze 3-zdaniowe przypomnienie z nazwą produktu i kwotą (przy błędzie LLM idzie stały szablon) → Gmail → `mark_followup_sent`. Potem `mark_lost_quotes(14)` → mail z 4 linkami ankiety.

- [ ] **Step 1: Napisz testy:** `test_followup_day3`, `test_followup_day7` (zamówienie sprzed 8 dni z `followups_sent=1` daje numer 2), `test_no_followup_after_approved`, `test_mark_lost_after_15_days` (a sprzed 13 dni pozostaje `quoted`), `test_followup_idempotent` (drugie `mark_followup_sent(id,1)` zwraca false).
- [ ] **Step 2: Uruchom.** Expected: FAIL.
- [ ] **Step 3: Zaimplementuj migrację 006. Codex buduje workflow 09.**
- [ ] **Step 4: Uruchom testy SQL i `scripts/test-followup.sh`** (zamówienia z cofniętym `quoted_at` → ręczny run 09 → `followups_sent` wzrosło; z `X-LLM-Mock: garbage` mail i tak wychodzi z szablonu). Expected: OK.
- [ ] **Step 5: Commit** `feat: quote follow-ups and lost-reason survey`.

### Task 9: Triage skrzynki AI (weekend / pon. 9.11)

**Files:**
- Create: `supabase/migrations/010_inbox.sql`
- Create: `n8n/workflows/10-inbox-triage.json`, `n8n/prompts/triage.md`, `data/faq.md`
- Create: `n8n/fixtures/email-question.txt`, `email-complaint.txt`, `email-spam.txt` oraz `llm-triage-{order,question,complaint,spam,uncertain}.json`
- Create: `scripts/test-triage.sh`
- Modify: `n8n/workflows/01-order-intake.json` (IMAP Trigger przenosi się do 10, a 01 dostaje wejście `Execute Workflow Trigger` obok webhooka)

**Interfaces:**
- Consumes: workflow 01 (intake), `00-llm`.
- Produces: tabela `inbox_messages(id, external_id text unique, from_email, subject, category check in ('order','question','complaint','spam','unknown'), confidence numeric, draft_id text, created_at)`.
- LLM zwraca `{category, confidence, reply_draft?}`. Reguły routingu: `order`, `confidence < 0.7`, niepoprawny JSON albo `unknown` przekazują mail do workflow 01, który sam ustawi `needs_review`, jeśli to nie zamówienie. `question` tworzy szkic odpowiedzi w Gmailu na podstawie `data/faq.md` (node „Create draft”, nigdy „Send”). `complaint` wysyła alert do właściciela i tworzy szkic potwierdzenia przyjęcia. `spam` dostaje tylko etykietę Gmail `spam-ai`.
- Testy: `POST /webhook/triage-test` przyjmuje sztuczny mail tylko przy `ALLOW_LLM_MOCK=1`.

- [ ] **Step 1: Napisz `scripts/test-triage.sh`:** `triage_order_goes_to_intake` (powstaje wiersz w `orders`), `triage_question_creates_draft_not_send` (`draft_id` niepusty, a wykonanie n8n nie zawiera node'a Send), `triage_uncertain_goes_to_intake` (spam z confidence 0,5 trafia do `orders`), `triage_garbage_goes_to_intake`, `triage_idempotent` (ten sam `external_id` daje jeden wiersz w `inbox_messages`).
- [ ] **Step 2: Uruchom.** Expected: FAIL (404).
- [ ] **Step 3: Claude robi migrację 007. Codex buduje workflow 10 i zmianę w 01.**
- [ ] **Step 4: Uruchom `test-triage.sh` i `test-intake.sh`** (intake nie może się zepsuć po zmianie). Expected: OK.
- [ ] **Step 5: Commit** `feat: AI inbox triage with human-approved drafts`.

### Task 10: Statusy zamówień i prośba o opinię (pon. 9.11)

**Files:**
- Create: `supabase/migrations/011_status.sql`
- Test: `supabase/tests/009_status_test.sql`
- Create: `n8n/workflows/11-status-notify.json`, `n8n/workflows/12-review-request.json`, `web/status.html`, `scripts/test-status.sh`

**Interfaces:**
- Consumes: `orders.public_token`, `orders.review_requested_at` (Task 1).
- Produces: tabela `order_events(id, order_id, old_status, new_status, created_at, notified_at)` wypełniana triggerem `trg_order_status` (AFTER UPDATE OF status, gdy `old.status is distinct from new.status`).
- Produces: `pending_order_events() returns setof order_events` (`notified_at is null` i `new_status in ('approved','in_progress','done')`, bo `quoted` obsługuje już intake) oraz `mark_event_notified(p_id uuid)`.
- Produces: `order_status_public(p_token uuid) returns jsonb` w kształcie `{status, label_pl, timeline:[{status, label_pl, at}]}`. Funkcja jest `security definer`, z `grant execute to anon`. Nie zwraca maila, cen ani id. Nieznany token zwraca `{}`.
- Produces: `orders_due_review() returns setof uuid`, czyli `done` od co najmniej 7 dni z `review_requested_at is null`.
- Workflow 11: cron co 2 min → `pending_order_events` → mail z szablonu (bez LLM) z linkiem `status.html?token=` → `mark_event_notified`. Cron zamiast webhooka z bazy, bo n8n działa lokalnie i nie jest wystawione do internetu.
- Workflow 12: cron codziennie → `orders_due_review` → mail z linkiem do opinii Google (klucz `google_review_url` w `settings`, w demo fikcyjny) i prośbą o zdjęcie → `review_requested_at = now()`.
- `web/status.html` (pisze Gemini): woła RPC `order_status_public` przez Supabase REST z kluczem publishable (anon). Pokazuje oś czasu po polsku, a przy `{}` komunikat „Nie znaleziono zamówienia”.

- [ ] **Step 1: Napisz testy:** `test_trigger_logs_status_change`, `test_no_event_when_status_same`, `test_public_status_hides_email` (w wyniku brak kluczy z mailem i `quote`), `test_invalid_token_returns_empty`, `test_review_request_once` (po ustawieniu `review_requested_at` zamówienia nie ma w `orders_due_review`).
- [ ] **Step 2: Uruchom.** Expected: FAIL.
- [ ] **Step 3: Claude robi migrację 008. Codex buduje workflowy 11 i 12, Gemini pisze `web/status.html`.**
- [ ] **Step 4: Uruchom testy SQL i `scripts/test-status.sh`** (approve zamówienia → w ciągu 2 min `notified_at` ustawione; otwórz `status.html?token=` i sprawdź oś czasu, a z losowym tokenem komunikat o braku zamówienia). Expected: OK.
- [ ] **Step 5: Commit** `feat: order status tracking and review requests`.

---

## Podział pracy między agentów

Zasada: **kto pisze, ten nie recenzuje**. Claude dyryguje: pisze briefy, uruchamia testy, weryfikuje diffy i robi commity. Codex i Gemini piszą kod wyłącznie w osobnych worktree (`delegate/<temat>`), a do głównej gałęzi trafia tylko to, co Claude sprawdził testami.

| Task | Pisze | Recenzuje | Dlaczego |
|---|---|---|---|
| 1–2: SQL, wycena, magazyn | Claude | Codex | Spójność danych i transakcje zostają przy dyrygencie, który ma Supabase MCP |
| 3–4: workflowy n8n (JSON) i skrypty testowe | Codex (`codex exec` w worktree) | Gemini | Dużo powtarzalnego JSON-a; Claude odpala `test-*.sh` przed merge |
| 5: SQL raportów | Claude | Codex | Jak wyżej |
| 5: `web/index.html` | Gemini (`agy-delegate --yolo` w worktree) | Codex | Front i polskie teksty; inna rodzina modeli niż recenzent |
| 6: README, demo | Claude | Gemini (perspektywa rekrutera) | Gemini dobrze czyta długi tekst |
| 7–8, 10: SQL zakupów, follow-upów i statusów | Claude | Codex | Jak w Task 1–2 |
| 7–10: workflowy 08–12 | Codex | Gemini | Jak w Task 3–4 |
| 10: `web/status.html` | Gemini | Codex | Jak kalkulator |

**Kolejność, gdy zabraknie czasu:** Task 7 → 8 → 6 (README i demo w piątek na pewno) → 9 → 10. Task 9 i 10 mogą wyjść poza piątek.

Ograniczenia: nikt poza Claude nie dostaje kluczy ani `.env`. Wyniki recenzji Gemini są weryfikowane przed przekazaniem, bo zdarza mu się zmyślać szczegóły. Wymagany jest `git init` w folderze projektu, żeby worktree działały.

## LLM w workflowach n8n

Decyzja z 2026-11-02: **lokalnie przez `agy`**, bez klucza API. Konsekwencje i sposób wykonania:

- **Jeden punkt wymiany.** Wszystkie wywołania LLM idą przez sub-workflow `n8n/workflows/00-llm.json` (wejście `{prompt, mode}`, wyjście `{text}`). Workflowy 01, 06 i 07 wołają go przez `Execute Workflow`. Zmiana na API w przyszłości to podmiana jednego node'a, co warto opisać w README jako świadomą decyzję.
- **Wewnątrz sub-workflow:** Code (prompt → base64) → `Execute Command`: `printf %s '<base64>' | base64 -d | LLM_MOCK='<nazwa>' "$PROJECT_DIR/scripts/llm.sh"` → Code (wynik albo pusty tekst przy błędzie). Walidacja odpowiedzi (wycięcie bloku ```json, mapowanie nazw na id) jest po stronie wywołującego.
- **`scripts/llm.sh`** (Task 3): czyta prompt ze stdin i woła `agy --model gemini-3.8-flash-medium --print-timeout 90s --print`. Przy `LLM_MOCK=<nazwa>` (tylko z `ALLOW_LLM_MOCK=1`, nazwa `^[a-z0-9-]+$`) zwraca zawartość fixture'a bez wołania `agy`; tego trybu używają skrypty testowe, żeby nie zużywać limitu.
- **n8n:** start przez `NODES_EXCLUDE="[]" npx n8n` (node `Execute Command` jest domyślnie wyłączony) oraz `N8N_BLOCK_ENV_ACCESS_IN_NODE=false`, bo workflowy czytają konfigurację przez `$env`. Wszystko ustawia `scripts/n8n.sh`.
- **Ograniczenia:** odpowiedź trwa 10–30 s, więc intake odpowiada na webhook od razu (`status: processing`), a wycena idzie mailem. Kalkulator nie korzysta z LLM (`quote_preview` to czysty SQL), więc działa natychmiast. Wywołania zużywają limit Google AI Pro, a system działa tylko przy włączonym komputerze.

## Co jest potrzebne od Ciebie (ok. 1–2 h w tygodniu)

- Pon.: konto Supabase (darmowe). Klucz LLM nie jest potrzebny.
- Wt.: skrzynka Gmail demo z hasłem aplikacji do IMAP, wpisywana przez Ciebie w n8n.
- Śr.: workspace Slack albo decyzja „powiadomienia tylko mailem”.
- Pt.: nagranie wideo demo według scenariusza.
