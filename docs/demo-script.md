# Scenariusz demo (3 minuty)

## Przygotowanie

```bash
supabase start
ALLOW_LLM_MOCK=1 scripts/n8n.sh start   # tryb testowy: ręczne uruchamianie cronów i atrapy modelu, ale BEZ prawdziwej wysyłki
node scripts/serve-web.mjs              # kalkulator, tablet salonowy i strona statusu na http://localhost:8080
```

Tryb testowy nie dostarcza wiadomości na Slacka ani mailem (to zabezpieczenie testów). Jeśli chcesz pokazać prawdziwe powiadomienia, uruchom n8n bez `ALLOW_LLM_MOCK` i `EMAIL_DELIVERY=on` w `.env.local` (maile wychodzą tylko na `EMAIL_ALLOWLIST`), a crony uruchamiaj funkcjami SQL (np. `select create_purchase_orders('http://localhost:5678')`) zamiast webhooków testowych. **Prawdziwy model trwa:** klasyfikacja ok. 50 s i parsowanie zamówienia kolejne ok. 50 s, więc wyślij `/triage` na początku i opowiadaj problem w tym czasie, albo użyj atrap (`X-LLM-Mock`, `X-Intake-Mock`) dla tempa nagrania.

Otwórz Slack `#zamowienia-demo` i podgląd kolejki maili (`select kind, to_email, subject from email_outbox order by created_at desc`). Token salonu: `select access_token from showrooms where code = 'warszawa-mokotow'`. Hasło operatora do linków zatwierdzeń leży w `.env.local` (`OPERATOR_PASSWORD`).

## Przebieg

| Czas | Co pokazujesz | Co mówisz |
|---|---|---|
| 0:00–0:15 | Problem: mail „potrzebuję komodę z dębu, 120 cm” | Właściciel dostaje takie maile codziennie i wycenia je ręcznie. |
| 0:15–0:40 | `POST /webhook/triage` z treścią maila → klasyfikacja `order` → intake → zamówienie `quoted`, mail z wyceną w kolejce | AI tylko czyta tekst, a trasę wybiera baza: niepewny albo błędny wynik modelu idzie do intake, nic nie ginie. Cenę liczy funkcja SQL. |
| 0:40–1:05 | Link zatwierdzenia (Basic Auth) → rezerwacja materiałów, zadanie na Slacku | Człowiek zatwierdza, system rezerwuje i przydziela pracę. Przy braku materiału dostaje alert z najtańszą hurtownią. |
| 1:05–1:25 | `POST /webhook/po-run` → szkic zamówienia do hurtowni na Slacku → link → mail do hurtowni → link „dostawa dotarła” → stan wzrósł | Braki zamawiamy u najtańszego dostawcy (cena nie starsza niż 30 dni). Zatwierdzenie to jedno kliknięcie. |
| 1:25–1:40 | Kalkulator na http://localhost:8080: komoda, zmiana materiału, cena na żywo, „Zamawiam” | Publiczne API nie ujawnia kosztów ani marży. Ponowienie żądania nie dubluje zamówienia. |
| 1:40–2:00 | Tablet `showroom.html?salon=warszawa-mokotow#<token>`: imię, e-mail, zgoda, komoda, „Wyślij wycenę klientowi” | Salon identyfikuje token, a handlowca i nazwę salonu zawsze podaje baza. Bez pozycji powstaje lead do oddzwonienia. |
| 2:00–2:20 | `status.html?token=…` otwarty z maila: oś czasu, po „Zakończ zadanie” etap „Gotowe” | Klient widzi tylko etapy i daty. Publiczna funkcja bazy zwraca bez e-maila i cen. |
| 2:20–2:40 | Wycena sprzed 4 dni → `POST /webhook/followup-run` → przypomnienie w kolejce; po 14 dniach status `lost` i ankieta | Przypomnienie pisze model, ale do klienta trafia tylko po walidacji, inaczej idzie stały szablon. |
| 2:40–2:50 | `POST /webhook/weekly-report` → bestsellery i podsumowanie AI na Slacku | Raport liczy baza, a model tylko streszcza. |
| 2:50–3:00 | `scripts/test-sql.sh` i `scripts/test-status.sh` | Każdy element ma testy, a granice systemu opisuje README. |

## Zabezpieczenie na wypadek awarii demo

- Gdy `agy` zwleka: dodaj nagłówek `X-LLM-Mock: triage-order` i `X-Intake-Mock: catalog` do `/triage` (fixtures w `n8n/fixtures`).
- Wysyłka maili jest domyślnie wyłączona, więc pokazujesz kolejkę `email_outbox`, a nie skrzynkę.
- Skrypty testowe (`scripts/test-*.sh`) po sobie sprzątają, ale zmieniają stany magazynu na czas przebiegu, więc nie uruchamiaj ich w trakcie nagrania.
