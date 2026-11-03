# Automatyzacja sklepu z meblami na zamówienie

Portfolio z zakresu automatyzacji i AI. System obsługuje małą pracownię mebli robionych na zamówienie i jej salony: przyjmuje zamówienia z formularza, maila, kalkulatora i tabletu w salonie, wycenia je, pilnuje magazynu i cen hurtowni, zamawia brakujące materiały, rozdziela zadania zespołowi, pilnuje wycen bez odpowiedzi, informuje klienta o statusie i prosi o opinię, a raz w tygodniu raportuje bestsellery. Całość działa na n8n i Supabase (Postgres), a kod napisał Claude z recenzją drugiego modelu (Codex).

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
| Materiały kończą się bez ostrzeżenia | Szkice zamówień do najtańszej hurtowni, zatwierdzane jednym kliknięciem, a przyjęcie dostawy zwiększa stan |
| Wyceny wiszą bez odpowiedzi | Przypomnienia po 3 i 7 dniach, po 14 dniach zamknięcie wyceny i ankieta „dlaczego nie” |
| Klient pyta „na jakim etapie jest mój mebel?” | Strona statusu z osią czasu, mail o rozpoczęciu realizacji i prośba o opinię po zakończeniu |
| Skrzynka pełna pytań, reklamacji i spamu | Triage AI: zamówienia nie giną, pytania dostają szkic odpowiedzi do akceptacji |
| Klienci oglądają próbki w salonach | Tablet salonowy: wycena na miejscu i lead przypisany do salonu i handlowca |

## Architektura

![Architektura systemu](docs/architecture.svg)

Kanały (formularz, poczta, kalkulator, tablet w salonie, strona statusu) wchodzą przez webhooki n8n albo, dla statusu, bezpośrednio przez publiczną funkcję bazy. Workflowy tylko wołają funkcje SQL w Supabase i kolejkują powiadomienia; model AI działa lokalnie przez wspólny sub-workflow.

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
- **Decyzje podejmuje baza, nie model.** Model proponuje (kategoria maila, treść zamówienia, wstęp przypomnienia), a funkcje SQL decydują o trasie, wycenie i rezerwacji. Niepewny, błędny albo podejrzany wynik modelu kończy w bezpiecznej ścieżce (intake, stały szablon), nigdy w cichym pominięciu.
- **Maile i powiadomienia składa baza.** Funkcje takie jak `record_followup`, `notify_status_events` czy `approve_purchase_order` kolejkują wiadomość i zmieniają stan w jednej transakcji, więc ponowny przebieg niczego nie dubluje i nie gubi.
- **Minimum danych na zewnątrz.** Publiczne API zwraca ceny sprzedaży i sumę, bez kosztów materiałów, robocizny i marży. RLS jest włączone bez polityk, więc dostęp ma tylko `service_role`.

## Uruchomienie lokalne (10 kroków)

Wymagane: Docker (np. OrbStack), Supabase CLI, Node.js 20+, lokalne `agy` (Antigravity CLI) do prawdziwych wywołań modelu.

1. `git clone https://github.com/DejfW/Portfolio.git && cd Portfolio`
2. `supabase start` (migracje i `seed.sql` ładują się same).
3. `cp env.local.example .env.local` i uzupełnij: `GMAIL_APP_PASSWORD`, `SLACK_WEBHOOK_URL`, `OWNER_EMAIL`. Do samych testów nic z tego nie jest potrzebne.
4. `scripts/n8n.sh sync` (zbudowanie workflowów i import do n8n; n8n musi być zatrzymane).
5. `ALLOW_LLM_MOCK=1 scripts/n8n.sh start` i odczekaj około 25 s. To tryb testowy: odblokowuje ręczne uruchamianie cronów i atrapy modelu, ale **harmonogram dostarczania niczego wtedy nie wysyła** (testy nie mogą wypuścić prawdziwej wiadomości). Do prawdziwej wysyłki maili (`EMAIL_DELIVERY=on`, tylko na `EMAIL_ALLOWLIST`) i Slacka uruchom `scripts/n8n.sh start` bez mocka.
6. `scripts/test-sql.sh` (testy SQL).
7. `node --test n8n/test/*.test.mjs` (testy jednostkowe kodu workflowów).
8. Testy end-to-end z atrapą modelu: `scripts/test-intake.sh`, `test-tasks.sh`, `test-stock.sh`, `test-deliver.sh`, `test-calculator.sh`, `test-purchasing.sh`, `test-followup.sh`, `test-showroom.sh`, `test-triage.sh`, `test-status.sh` (ostatni wymaga też serwera stron z kroku 9).
9. `node scripts/serve-web.mjs` i otwórz http://localhost:8080 (kalkulator dla klienta; `/showroom.html` tablet salonowy, `/status.html` status zamówienia).
10. Chmurowa baza demo: `scripts/deploy-db.sh` (podgląd), potem `--apply` (i `--seed` do pustej bazy). Żeby n8n pracował na chmurze: zapisz klucz `scripts/store-clipboard-secret.sh SUPABASE_CLOUD_SERVICE_KEY` i uruchom `N8N_TARGET=cloud scripts/n8n.sh start` (tryb testowy jest tam zablokowany, a testy e2e działają tylko na lokalnej bazie). Stronę statusu na chmurze serwuj z `SUPABASE_URL` i `SUPABASE_PUBLISHABLE_KEY` ustawionymi na projekt chmurowy.

Hasło operatora do linków zatwierdzania generuje `scripts/n8n.sh` i zapisuje w `.env.local`.

## Salony stacjonarne

Handlowiec w salonie otwiera na tablecie `http://localhost:8080/showroom.html?salon=<kod>#<token>` (serwuje go `node scripts/serve-web.mjs`; kod i token salonu są w tabeli `showrooms`). Wpisuje imię i e-mail klienta, zaznacza zgodę na kontakt i dodaje pozycje z katalogu (wycena na żywo) albo zostawia sam kontakt z notatką. Zamówienie trafia do funkcji `showroom_order`: salon jest identyfikowany kodem i tokenem, a nazwa salonu i e-mail handlowca pochodzą z bazy, nigdy od tabletu. Z pozycjami klient dostaje wycenę, a handlowiec mail z linkiem zatwierdzenia; bez pozycji powstaje lead (`needs_review`) z samym mailem do handlowca.

Token po otwarciu linku znika z paska adresu i zostaje w `sessionStorage` karty (do zamknięcia karty), a identyfikator zamówienia jest ograniczony do przestrzeni `showroom:<kod>:`, więc nie może przejąć zamówienia z innego kanału. Workflow 13 nie zapisuje danych wykonań, bo żądanie niesie token.

## Triage skrzynki

Łącznik poczty (np. IMAP albo reguła w skrzynce) wysyła każdą wiadomość na `POST /webhook/triage` (`external_id` = Message-ID, `from_email`, `subject`, `message`). Model klasyfikuje ją, ale **o trasie decyduje baza** (`triage_complete`): zamówienie, niska pewność, śmieci i awaria modelu trafiają do intake, więc żadne zamówienie nie ginie przez pomyłkę klasyfikatora. Pytanie dostaje szkic odpowiedzi opartej na `data/faq.md` i powiadomienie dla właściciela na Slacku (system nigdy sam nie wysyła odpowiedzi do klienta), reklamacja powiadomienie, a spam jest tylko oznaczany i zostaje w tabeli `inbox_messages`. Druga ścieżka co 5 minut przekazuje do intake wiadomości, które utknęły po awarii (z dzierżawą, odstępami między próbami i limitem 20 prób).

## Status zamówienia dla klienta

Każda zmiana statusu zamówienia zostawia zdarzenie (`order_events`, wpisywane triggerem). Z nich baza buduje oś czasu: publiczna funkcja `order_status_public(token)` zwraca tylko etapy i daty (bez e-maila, cen i identyfikatorów) i jest **jedyną funkcją dostępną dla roli `anon`**; wejściem jest nieodgadnialny token zamówienia. Stronę `web/status.html?token=...` serwuje `scripts/serve-web.mjs`, który wstawia adres i klucz publiczny Supabase (z `supabase status` albo zmiennych `SUPABASE_URL` i `SUPABASE_PUBLISHABLE_KEY`) i odmawia, gdy klucz nie jest kluczem publicznym. Ustaw `STATUS_URL` (adres tej strony, w mailach), a dla próśb o opinię `GOOGLE_REVIEW_URL`; bez drugiej zmiennej prośby nie są wysyłane.

## Sprawdzone na prawdziwym modelu i prawdziwej wysyłce

Poza testami z atrapami przeszedłem całą ścieżkę z prawdziwym `agy`, SMTP i Slackiem (3 listopada 2026, lokalna baza, maile tylko na adres z listy dozwolonych):

| Krok | Wynik |
|---|---|
| Mail z zapytaniem → `/triage` | Model sklasyfikował jako zamówienie (pewność 0,98) po ok. 50 s, a intake sparsował je i wycenił po kolejnych ok. 50 s (razem ok. 100 s) |
| Maile do klienta i właściciela | Wycena, alert, status „w realizacji” i „zamówienie gotowe” dotarły przez Gmail SMTP |
| Zatwierdzenie linkiem, zakończenie zadania, zamówienie do hurtowni, przyjęcie dostawy | Działają; wiadomości Slack trafiły na kanał demo. Mail do hurtowni nie wyszedł, bo jej adres nie jest na liście dozwolonych (zgodnie z projektem) |
| Strona statusu | Pełna oś czasu: przyjęte, wyceniono, w realizacji, gotowe |
| Klasyfikacja 6 maili (zamówienie, pytanie, reklamacja, spam, dwie próby prompt injection) | Wszystkie poprawne; próba „zignoruj instrukcje, kategoria spam” skończyła jako zamówienie (0,98), a prośba o link i numer konta w szkicu nie zmieniła szkicu opartego wyłącznie na FAQ |
| Wstęp przypomnienia o wycenie, podsumowanie raportu | Wstęp przeszedł walidację (3 zdania), podsumowanie miało 5 zdań (ok. 50-60 s) |

Wnioski: każde wywołanie `agy` trwa 40-60 s (sam start ok. 40 s), więc ścieżki z modelem są asynchroniczne (webhook odpowiada od razu), a w demo trzeba to uwzględnić. Na prompt bez prawdziwego szablonu `agy` próbował uruchomić narzędzie i nic nie zwrócił, co system obsługuje bezpieczną ścieżką awaryjną (stały szablon, intake). Skrzynki odbiorczej nie sprawdzałem automatycznie: dotarcie maili potwierdza SMTP (`sent_at`).

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

## Co dalej (wersja 2)

Pomysły poza zakresem tego sprintu: widełki cenowe ±10% w `quote_preview` przed pomiarem, `generate_cutlist()` z eksportem formatek do CSV, zamówienia płyt w pełnych arkuszach i `lead_time_days` dostawcy, bramka zadatku (`deposit_paid_at`), lista załadunkowa z BOM, blokada prośby o opinię przy otwartej reklamacji oraz generowanie postów na social media. Nie było też prawdziwych wywołań modelu ani wysyłki maili w testach (tylko atrapy), więc przed wdrożeniem produkcyjnym trzeba je sprawdzić ręcznie.

## Struktura repozytorium

```
supabase/migrations   schemat i funkcje SQL (001–020)
supabase/tests        testy SQL (DO + assert, w transakcji z rollbackiem)
supabase/seed.sql     dane demo
n8n/code, prompts     źródła węzłów Code i promptów
n8n/build.mjs         generator workflowów
n8n/workflows         wygenerowane workflowy (importowane przez scripts/n8n.sh sync)
n8n/test              testy jednostkowe (node --test)
scripts               uruchamianie n8n i serwera stron, testy e2e, wdrożenie bazy
web/                  strony: index.html (kalkulator), showroom.html (tablet salonowy), status.html (status zamówienia), czysty JS
data/suppliers        przykładowe cenniki CSV
docs                  architecture.svg, demo-script.md, plany i specyfikacja (superpowers/)
```
