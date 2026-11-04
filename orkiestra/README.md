# orkiestrA: orkiestrator agentów programistycznych

Lokalna aplikacja, która z jednego celu („dodaj eksport CSV do raportów”) robi plan zadań i rozdziela je między agentów kodujących (Claude Code, Codex, Antigravity), każdego w osobnym worktree gita. Wynik każdego zadania ocenia sędzia, a zaakceptowane zadania scala w gałąź integracyjną i sprawdza testami. Plan, sędziego i routing robi lokalny model (Ollama), więc ta część nic nie kosztuje i nie wysyła kodu na zewnątrz.

Kod napisał Claude. Wszystko w `agent-orch/` działa na samej bibliotece standardowej Pythona (bez `pip install`).

## Problem

Przy kilku agentach CLI trzeba ręcznie: pociąć zadanie na części, wybrać, który agent i model do czego, pilnować limitów (każdy dostawca ma własne okno zużycia), sprawdzić, czy zmiana nie psuje testów, i poskładać wyniki. Orkiestra robi to w pętli i pokazuje przebieg na żywo w przeglądarce.

## Jak to działa

```
cel + repo ──► pytania doprecyzowujące (opcjonalnie)
           ──► planer (lokalny model): zadania, kategoria, trudność, zależności, kryterium akceptacji
           ──► router: najtańszy profil (agent + model + effort), który jest dość mocny do zadania
           ──► scheduler: do 3 zadań równolegle, każde w osobnym worktree gita
           ──► sędzia: accept / retry / reassign na podstawie diffa, testów i podsumowania agenta
           ──► merge do gałęzi integracyjnej; merge, który psuje testy, jest cofany
           ──► sędzia końcowy: czy cel jest spełniony
```

| Moduł | Zadanie |
|---|---|
| `planner.py` | Cel → lista zadań (JSON wymuszony schematem). Usuwa cykle i nieznane zależności, a zadania na tym samym pliku łączy w łańcuch, żeby nie powstawały konflikty. |
| `router.py` | Wybiera profil: najniższy koszt spośród profili o wystarczającym poziomie (`tier`) i dobrych w danej kategorii. Przy niepowodzeniu eskaluje: najpierw ten sam agent poziom wyżej, potem inny agent, nigdy słabszy i nigdy ten sam dwa razy. |
| `scheduler.py` | Pętla wykonawcza: zależności, równoległość, ponowienia (kolejna próba startuje od odrzuconej gałęzi i dostaje powód odrzucenia), budżet i limit czasu na przebieg, anulowanie, wznawianie po awarii. |
| `judge.py` | Sędzia pracy agenta i sędzia końcowy. Duży diff jest skracany z jawnym znacznikiem `[... N lines omitted ...]`, a treść z repo traktowana jest jako dane (ochrona przed prompt injection między agentami). Zadania trudne dostają dodatkowo recenzję agenta **innego dostawcy**, w trybie tylko do odczytu. |
| `probe.py`, `capabilities.py` | Sprawdzają, którzy agenci są zainstalowani i zalogowani oraz ile zostało z limitów. Profile współdzielące limit tworzą *pulę*: w danej chwili działa jedno zadanie na pulę, a wyczerpanie limitu wyłącza całą pulę. |
| `gitops.py` | Worktree, commity, merge, wykrywanie konfliktów (konflikt rozwiązuje osobny agent). |
| `projgen.py` | Strona „New project”: model proponuje, jakie MCP, wtyczki i skille zainstalować, a instalacja idzie tylko po potwierdzeniu i tylko komendami z listy dozwolonych (`install_allow`). |
| `suggestions.py` | Podpowiedzi na dashboardzie (nieudane przebiegi do wznowienia, wyczerpane limity, profile o niskiej skuteczności). |
| `main.py`, `static/index.html` | Serwer HTTP (`ThreadingHTTPServer`, SSE do podglądu na żywo) i jednoplikowy dashboard bez bibliotek. |
| `db.py` | SQLite: przebiegi, zadania, zdarzenia, próby (czas, tokeny, koszt). |

Profile i ich poziomy są w `agent-orch/orch.toml`. To punkt wyjścia, nie pomiar: `tier`, `cost` i `good` trzeba dostroić do własnych zadań. Do tego służy `calib/` (mini zadania z automatycznym sprawdzaniem, po jednym na kategorię routera; wyniki w `calib/results-*.json`).

## Decyzje projektowe

- **Decyzje podejmuje kod, nie model.** Model proponuje plan i werdykt, ale o routingu, eskalacji, budżecie i scalaniu decyduje deterministyczny kod. Zła odpowiedź modelu kończy się bezpiecznym domyślnym wyborem (nieznana kategoria → wartość domyślna, nieprawidłowy profil → zastąpiony).
- **Izolacja przez git.** Każde zadanie pracuje w osobnym worktree, więc równoległe zadania sobie nie przeszkadzają, a odrzucona próba nie brudzi gałęzi głównej. Praca ląduje na gałęzi `orch/run-<id>`, nigdy bezpośrednio na bieżącej.
- **Testy jako bramka.** Po każdym merge uruchamiany jest `test_cmd` przebiegu. Merge, który psuje testy, jest cofany.
- **Limity jako obiekt pierwszej klasy.** Pule limitów, budżet (`run_budget`), limit czasu (`run_max_minutes`) i wykrywanie wyczerpania limitu po tekście błędu agenta.
- **Agent, który milczy, jest zabijany** (`agent_idle_timeout`), razem z całym drzewem procesów.
- **Nic nie wychodzi poza maszynę poza wywołaniami agentów.** Serwer słucha na `127.0.0.1`, plan i sędzia chodzą na lokalnym modelu.

## Uruchomienie

Wymagane: Python 3.11+ (`tomllib`), git, [Ollama](https://ollama.com) z modelem `qwen3:8b` (`ollama pull qwen3:8b`) oraz przynajmniej jeden zainstalowany i zalogowany agent CLI (`claude`, `codex` lub `agy`). Profile niedostępnych agentów są po prostu pomijane.

```bash
./start.sh          # z dowolnego katalogu; otwiera http://127.0.0.1:8765
```

Konfiguracja: `agent-orch/orch.toml`, a pojedyncze wartości można nadpisać zmienną `ORCH_<NAZWA>` (np. `ORCH_PORT=9000`, `ORCH_MAX_PARALLEL=2`). Baza (`orch.db`) i worktree (`.orch/`) są w `.gitignore`.

Testy (63 testy `unittest`, bez dostępu do sieci i prawdziwych agentów):

```bash
cd agent-orch && python3 -m unittest discover -s tests -t .
```

## Design system i makiety

Poza aplikacją repozytorium zawiera osobny, statyczny zestaw materiałów projektowych dla interfejsu orkiestry:

| Katalog | Zawartość |
|---|---|
| `design-system.md`, `styles/` | Tokeny (kolory, typografia, odstępy, promienie), ciemny motyw przez `prefers-color-scheme` |
| `components/` | Nagłówek, pasek boczny i treść główna jako komponenty HTML + CSS |
| `responsive/` | Układy desktop, tablet, mobile i widok master-detail |
| `accessibility/` | Landmarki, nawigacja klawiaturą, formularze i dialogi (WCAG AA) |
| `mockups/` | 6 makiet SVG (logowanie, dashboard, przebieg, zadanie, nowy przebieg, mobile) |

Uwaga: to materiał projektowy, a **działający dashboard** (`agent-orch/orch/static/index.html`) ma własne, wbudowane style i nie importuje tych plików. Makieta logowania nie ma odpowiednika w aplikacji (patrz niżej).

## Ograniczenia, które znam

- **Brak uwierzytelniania.** Dashboard i API nie wymagają logowania; bezpieczeństwo opiera się na nasłuchu na `127.0.0.1`. Nie wystawiaj portu na zewnątrz. Endpoint instalacji (`/api/projects/<id>/install/<n>`) uruchamia polecenia, ale tylko z listy `install_allow`, a UI prosi o potwierdzenie przed wywołaniem.
- **Agenci mają dostęp do sieci i narzędzi** (skille, wtyczki). Worktree chroni gałąź, ale nie jest piaskownicą systemu plików.
- **Wartości `tier`, `cost` i `good` to heurystyki startowe**, a nie wyniki benchmarku. `calib/` ma tylko po jednym małym zadaniu na kategorię, więc to sanity check, nie ranking modeli.
- **Sędzia to lokalny model 8B.** Jego werdykt jest filtrem, nie gwarancją poprawności; stąd testy po merge i recenzja drugiego dostawcy dla zadań trudnych.
- **Jedna maszyna, jeden proces.** Stan w SQLite, wątki zamiast kolejki zadań; restart serwera nie gubi przebiegów (`resume`), ale nie ma trybu wielu użytkowników.
- **Koszt `cost_usd` zależy od tego, co raportuje dany agent**, więc nie wszystkie próby mają wartość.

## Struktura

```
start.sh                  uruchamia agent-orch/run.sh z dowolnego katalogu
agent-orch/orch/          kod aplikacji (Python, tylko stdlib)
agent-orch/orch/static/   dashboard (jeden plik HTML)
agent-orch/orch.toml      profile agentów, limity, budżet
agent-orch/tests/         testy jednostkowe
agent-orch/calib/         kalibracja profili na mini zadaniach
design-system.md, styles/, components/, responsive/, accessibility/, mockups/
```
