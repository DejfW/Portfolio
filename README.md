# Automatyzacja sklepu z meblami na zamówienie

Portfolio z zakresu automatyzacji i AI. System obsługuje małą pracownię mebli robionych na zamówienie: przyjmuje zamówienia z formularza i maila, wycenia je, pilnuje magazynu i cen hurtowni, rozdziela zadania zespołowi i raz w tygodniu raportuje bestsellery. Całość działa na n8n i Supabase (Postgres), a kod napisał Claude z recenzją drugiego modelu (Codex).

Wszystkie firmy, adresy i klienci w danych demo są fikcyjne.

## Problem biznesowy

Właściciel małej pracowni traci czas na pracę, którą da się zautomatyzować:

| Ból | Co robi system |
|---|---|
| Zamówienia przychodzą mailem i formularzem w dowolnej formie | AI zamienia treść na ustrukturyzowane zamówienie, a wycenę liczy baza |
| Wycena „na oko” | Cena z cennika hurtowni + robocizna + marża + odpad, zawsze tym samym kodem |
| Brak materiału wychodzi dopiero przy pracy | Zatwierdzenie zamówienia rezerwuje materiały i od razu alarmuje o brakach |
| Szukanie najtańszej hurtowni | Codzienny import cenników CSV i `best_price` (tylko ceny nie starsze niż 30 dni) |
| Klient chce znać cenę od ręki | Publiczny kalkulator z wyceną na żywo i zamówieniem jednym kliknięciem |
| Nie wiadomo, co się sprzedaje | Poniedziałkowy raport bestsellerów na Slacku z podsumowaniem AI |

## Architektura

```
 klient ──► formularz / mail ─► [01 Order intake] ─► AI (agy) ─► walidacja ─┐
 klient ──► web/index.html ───► [06 Calculator] ─► quote_preview / calculator_order ─┤
                                                                           ▼
                                                       ┌────────────  SUPABASE (Postgres)  ───────────┐
                                                       │ orders, order_items, tasks, stock_movements, │
                                                       │ materials, supplier_prices, *_outbox         │
                                                       │ logika: wycena, rezerwacje, best_price,      │
                                                       │ raporty (funkcje SQL, testy w supabase/tests)│
                                                       └──────────────────────────────────────────────┘
        ▲                         ▲                         ▲                          │
 [03 Team tasks]          [04 Stock & prices]       [07 Weekly report]        [05 Deliver] co minutę
 link „zatwierdź”,        7:00, import CSV,         pon. 8:00, bestsellery    email_outbox → Gmail SMTP
 link „zrobione”          raport braków             + podsumowanie AI         slack_outbox → Slack
                                                                              (at-least-once)
```

### Workflowy n8n

| Plik | Wyzwalacz | Zadanie |
|---|---|---|
| `00-llm` | sub-workflow | Wywołanie lokalnego modelu przez `scripts/llm.sh` (bez klucza API) |
| `01-order-intake` | `POST /webhook/order` | Zamówienie z formularza lub maila → AI → walidacja → wycena → zapis |
| `02-intake-sweeper` | co 5 min | Wznawia zamówienia, które utknęły w przetwarzaniu |
| `03-team-tasks` | `GET/POST /webhook/approve`, `/task-done` | Zatwierdzenie przez właściciela (Basic Auth), rezerwacja materiałów, zadanie dla zespołu, zamknięcie zadania |
| `04-stock-prices` | 7:00 codziennie | Import cenników CSV, raport niskich stanów |
| `05-deliver` | co minutę | Wysyłka kolejek maili i Slacka |
| `06-calculator` | `GET /catalog`, `POST /quote-preview`, `POST /calculator-order` | Publiczne API kalkulatora |
| `07-weekly-report` | poniedziałek 8:00 | Bestsellery z 7 i 30 dni + podsumowanie AI na Slacku |
| `08-purchase-orders` | 7:15 codziennie, `GET/POST /webhook/po-approve`, `/po-received` | Szkice zamówień do hurtowni z materiałów poniżej minimum, zatwierdzenie linkiem (mail do hurtowni), przyjęcie dostawy zwiększa stan |
| `09-quote-followup` | 9:00 codziennie, `GET/POST /webhook/lost-reason` | Przypomnienia o wycenie po 3 i 7 dniach (wstęp pisze AI z walidacją i szablonem awaryjnym), po 14 dniach status `lost` i mail z ankietą powodu rezygnacji |
| `10-status-notify` | co 2 min | Mail do klienta o rozpoczęciu realizacji z linkiem do strony statusu (`status.html?token=`); maila składa baza (`notify_status_events`) |
| `11-inbox-triage` | `POST /webhook/triage`, co 5 min naprawa | Klasyfikacja poczty przez AI (zamówienie, pytanie, reklamacja, spam): zamówienia i niepewne przypadki idą do intake, pytania i reklamacje do właściciela na Slacku, spam jest tylko oznaczany |
| `12-review-request` | 10:00 codziennie | Prośba o opinię Google (i zdjęcie mebla) 7 dni po zakończeniu zamówienia, tylko gdy ustawiono `GOOGLE_REVIEW_URL` |
| `13-showroom` | `GET /webhook/showroom-info`, `POST /webhook/showroom-order` | API tabletu w salonie stacjonarnym: wycena dla klienta i mail do handlowca (lub sam lead z notatką) |

Pliki `n8n/workflows/*.json` są **generowane** przez `n8n/build.mjs` z `n8n/code/*.js` i `n8n/prompts/*.md`. Edytuje się źródła, nie JSON.

## Decyzje projektowe

- **Logika w SQL, nie w workflowach.** Wycena, rezerwacje i raporty to funkcje Postgresa z testami (`supabase/tests`). Workflow n8n tylko orkiestruje. Dzięki temu logikę da się testować bez uruchamiania n8n.
- **AI tylko tam, gdzie trzeba.** Model czyta tekst zamówienia i pisze podsumowanie raportu. Ceny, stany i decyzje liczy kod. Wynik modelu jest walidowany (kształt, produkty z katalogu, limity), a jego awaria nie gubi zamówienia ani raportu liczbowego.
- **Człowiek zatwierdza.** Zamówienie z maila nie rezerwuje materiałów, dopóki właściciel nie kliknie linku zatwierdzenia.
- **Idempotencja.** `upsert_order` i `calculator_order` działają po `external_id`, więc ponowienie żądania nie dubluje zamówienia. Klucz kalkulatora to skrót SHA-256 treści zamówienia.
- **Outbox.** Maile i wiadomości Slacka trafiają najpierw do tabel `email_outbox` i `slack_outbox` z kluczem deduplikacji, a `05-deliver` je wysyła. Dostarczanie jest *at-least-once*: po awarii wiadomość może pójść ponownie, ale nie zginie.
- **Bezpieczne domyślne ustawienia.** Wysyłka maili jest domyślnie wyłączona (`EMAIL_DELIVERY=off`), a po włączeniu idzie tylko na adresy z `EMAIL_ALLOWLIST`. Tryb testowy z mockiem LLM trzeba włączyć świadomie (`ALLOW_LLM_MOCK=1`).
- **Minimum danych na zewnątrz.** Publiczne API zwraca ceny sprzedaży i sumę, bez kosztów materiałów, robocizny i marży. RLS jest włączone bez polityk, więc dostęp ma tylko `service_role`.

## Uruchomienie lokalne (10 kroków)

Wymagane: Docker (np. OrbStack), Supabase CLI, Node.js 20+, lokalne `agy` (Antigravity CLI) do prawdziwych wywołań modelu.

1. `git clone https://github.com/DejfW/Portfolio.git && cd Portfolio`
2. `supabase start` (migracje i `seed.sql` ładują się same).
3. `cp env.local.example .env.local` i uzupełnij: `GMAIL_APP_PASSWORD`, `SLACK_WEBHOOK_URL`, `OWNER_EMAIL`. Do samych testów nic z tego nie jest potrzebne.
4. `scripts/n8n.sh sync` (zbudowanie workflowów i import do n8n; n8n musi być zatrzymane).
5. `ALLOW_LLM_MOCK=1 scripts/n8n.sh start` i odczekaj około 25 s (do demo bez mocka: `scripts/n8n.sh start`).
6. `scripts/test-sql.sh` (testy SQL).
7. `node --test n8n/test/*.test.mjs` (testy jednostkowe kodu workflowów).
8. `scripts/test-intake.sh`, `scripts/test-tasks.sh`, `scripts/test-stock.sh`, `scripts/test-deliver.sh`, `scripts/test-calculator.sh` (testy end-to-end z mockiem LLM).
9. `node scripts/serve-web.mjs` i otwórz http://localhost:8080 (kalkulator dla klienta).
10. Chmurowa baza demo: `scripts/deploy-db.sh` (podgląd), potem `--apply`.

Hasło operatora do linków zatwierdzania generuje `scripts/n8n.sh` i zapisuje w `.env.local`.

## Salony stacjonarne

Handlowiec w salonie otwiera na tablecie `http://localhost:8080/showroom.html?salon=<kod>#<token>` (serwuje go `node scripts/serve-web.mjs`; kod i token salonu są w tabeli `showrooms`). Wpisuje imię i e-mail klienta, zaznacza zgodę na kontakt i dodaje pozycje z katalogu (wycena na żywo) albo zostawia sam kontakt z notatką. Zamówienie trafia do funkcji `showroom_order`: salon jest identyfikowany kodem i tokenem, a nazwa salonu i e-mail handlowca pochodzą z bazy, nigdy od tabletu. Z pozycjami klient dostaje wycenę, a handlowiec mail z linkiem zatwierdzenia; bez pozycji powstaje lead (`needs_review`) z samym mailem do handlowca.

Token po otwarciu linku znika z paska adresu i zostaje w `sessionStorage` karty (do zamknięcia karty), a identyfikator zamówienia jest ograniczony do przestrzeni `showroom:<kod>:`, więc nie może przejąć zamówienia z innego kanału. Workflow 13 nie zapisuje danych wykonań, bo żądanie niesie token.

## Triage skrzynki

Łącznik poczty (np. IMAP albo reguła w skrzynce) wysyła każdą wiadomość na `POST /webhook/triage` (`external_id` = Message-ID, `from_email`, `subject`, `message`). Model klasyfikuje ją, ale **o trasie decyduje baza** (`triage_complete`): zamówienie, niska pewność, śmieci i awaria modelu trafiają do intake, więc żadne zamówienie nie ginie przez pomyłkę klasyfikatora. Pytanie dostaje szkic odpowiedzi opartej na `data/faq.md` i powiadomienie dla właściciela na Slacku (system nigdy sam nie wysyła odpowiedzi do klienta), reklamacja powiadomienie, a spam jest tylko oznaczany i zostaje w tabeli `inbox_messages`. Druga ścieżka co 5 minut przekazuje do intake wiadomości, które utknęły po awarii (z dzierżawą, odstępami między próbami i limitem 20 prób).

## Status zamówienia dla klienta

Każda zmiana statusu zamówienia zostawia zdarzenie (`order_events`, wpisywane triggerem). Z nich baza buduje oś czasu: publiczna funkcja `order_status_public(token)` zwraca tylko etapy i daty (bez e-maila, cen i identyfikatorów) i jest **jedyną funkcją dostępną dla roli `anon`**; wejściem jest nieodgadnialny token zamówienia. Stronę `web/status.html?token=...` serwuje `scripts/serve-web.mjs`, który wstawia adres i klucz publiczny Supabase (z `supabase status` albo zmiennych `SUPABASE_URL` i `SUPABASE_PUBLISHABLE_KEY`) i odmawia, gdy klucz nie jest kluczem publicznym. Ustaw `STATUS_URL` (adres tej strony, w mailach), a dla próśb o opinię `GOOGLE_REVIEW_URL`; bez drugiej zmiennej prośby nie są wysyłane.

## Ograniczenia, które znam

- **Statusy i opinie:** ważność maila (3 dni dla statusu, okno 7-60 dni dla opinii) sprawdzamy przy kolejkowaniu, a nie przy samej wysyłce; po długiej przerwie w dostarczaniu zalegający mail może wyjść spóźniony. Zakończenie zamówienia ma własny mail (`order_done`), więc status `done` nie wysyła drugiego.
- **Triage:** endpoint `/triage` uruchamia model, więc bez ustawionego `INTAKE_TOKEN` odrzuca żądania (poza trybem testowym); limit ruchu i kolejka AI należą do warstwy przed n8n. Spam to jedyna trasa bez dalszych skutków, więc oprócz pewności modelu (>= 0,9) wymagamy braku śladów zapytania o meble w treści, a odrzucony spam można przejrzeć (`select * from inbox_messages where route = 'spam'`). Heurystyka słów kluczowych nie zastępuje przeglądu; podatność modelu na prompt injection jest ograniczona, nie wyeliminowana. Szkice i treść dla właściciela mają rozbrojone adresy URL.
- **Salony:** token salonu wyciekający z tabletu pozwala kolejkować wyceny na dowolne adresy (do czasu rotacji tokenu, np. `update showrooms set access_token = ...`); przed publicznym wdrożeniem potrzebny jest limit żądań i antybot (reverse proxy). Sweeper naprawia brakujące maile salonu tylko dla zamówień w statusie `quoted` i `needs_review`, tak jak dla pozostałych kanałów.
- **Przypomnienia o wycenach:** wstęp maila pisze model, ale trafia do klienta tylko po przejściu walidacji (dokładnie 3 zdania, bez linków, adresów i znaków formatowania, bez fraz odmowy). To filtr heurystyczny, nie gwarancja treści; przy awarii lub podejrzanej odpowiedzi idzie stały szablon. Wyniki AI są dopasowywane do wycen po identyfikatorze, a nie po kolejności. Strony ankiety rezygnacji są publiczne i chronione tylko nieodgadnialnym tokenem zamówienia; pierwsza odpowiedź wygrywa.
- **Zamówienia do hurtowni:** szkic zachowuje ceny z chwili utworzenia, a materiał z otwartego szkicu lub wysłanego zamówienia nie trafia do kolejnego (nieprzyjęte lub niezatwierdzone zamówienie go blokuje). Ilość to uzupełnienie do dwukrotności minimum, bez uwzględnienia dostaw w drodze poza otwartymi zamówieniami.
- **Ochrona formularzy operatora (CSRF):** strony n8n są serwowane w piaskownicy CSP, więc formularz wysyła `Origin: null` i nie da się polegać na `Sec-Fetch-Site`. Odrzucamy POST z `Origin` innej witryny; dalszą ochroną są logowanie Basic i nieodgadnialny UUID w treści formularza. Dla wdrożenia produkcyjnego lepszy byłby podpisany token formularza.
- **Brak limitu żądań i antybota** na publicznych endpointach. n8n nie ma go wbudowanego, więc przed publicznym wdrożeniem potrzebny jest reverse proxy (np. Caddy lub Cloudflare).
- **Raport używa okna kroczącego** (7 i 30 dni od `created_at`) i wycenia sprzedaż po aktualnym cenniku, więc kwoty są przybliżone. Gdy pozycji nie da się wycenić, raport pokazuje „brak wyceny”, a nie 0 zł.
- **Prompt injection** w nazwach produktów jest tylko ograniczone (skracanie i oczyszczanie nazw, maksymalnie 10 wierszy w prompcie). Wynik AI w raporcie trafia wyłącznie na prywatny kanał Slacka.
- **Dostarczanie at-least-once**: pojedynczy mail może przyjść dwa razy po awarii w trakcie wysyłki.

## Co bym dodał w produkcji

- Reverse proxy z limitem żądań, Turnstile na formularzu i kalkulatorze.
- Kolejka zamiast odpytywania co minutę (np. `LISTEN/NOTIFY` lub pg_cron) oraz exactly-once dla maili przez identyfikator wiadomości po stronie dostawcy.
- Monitoring: alerty o nieudanych workflowach i rosnącej kolejce outboxów.
- Uwierzytelnianie operatora przez SSO zamiast jednego hasła Basic.
- Osobny projekt Supabase na dev, staging i produkcję z CI uruchamiającym `supabase db reset` i testy.
- Wersjonowanie cennika, żeby raporty liczyły sprzedaż po cenach z dnia zamówienia.

## Co dalej

Zaplanowane, jeszcze niewdrożone: automatyczne zamówienia do hurtowni, follow-up wycen, triage skrzynki z AI, statusy zamówień i prośby o opinię. Social media (generowanie postów) to pomysł na wersję 2.

## Struktura repozytorium

```
supabase/migrations   schemat i funkcje SQL (001–020)
supabase/tests        testy SQL (DO + assert, w transakcji z rollbackiem)
supabase/seed.sql     dane demo
n8n/code, prompts     źródła węzłów Code i promptów
n8n/build.mjs         generator workflowów
n8n/workflows         wygenerowane workflowy (importowane przez scripts/n8n.sh sync)
n8n/test              testy jednostkowe (node --test)
scripts               uruchamianie, testy e2e, wdrożenie bazy
web/index.html        kalkulator dla klienta (czysty JS)
data/suppliers        przykładowe cenniki CSV
docs                  plan sprintu i scenariusz demo (demo-script.md)
```
