# System automatyzacji stolarni i salonów: kontekst projektu (sprint 2–6.11.2026)

Dokument źródłowy dla planów w `docs/superpowers/plans/`. Zapisany z instrukcji kontekstowej z rozmowy 2026-11-03.

## 1. Cel i architektura bazowa

System automatyzacji dla małej stolarni mebli na zamówienie i sieci jej salonów stacjonarnych.

- **Jedyne źródło prawdy:** Supabase (PostgreSQL 15, funkcje RPC). Logika biznesowa, walidacje, transakcje (`SELECT ... FOR UPDATE`), wyceny i rezerwacje siedzą w bazie, co eliminuje wyścigi przy równoległych zleceniach.
- **Orkiestracja:** n8n (lokalnie przez `npx n8n`): wyzwalacze, webhooki, powiadomienia, wywołania LLM.
- **LLM:** lokalny model (`gemini-3.8-flash-medium` przez `agy --print`), prompt kodowany w base64 i przekazywany przez stdin do `scripts/llm.sh`. To eliminuje wstrzyknięcie komendy do powłoki; manipulowanie samym modelem (prompt injection) to osobne ryzyko, ograniczane walidacją wyniku.

## 2. Kontekst branżowy

1. **Zbieracze ofert:** filtrowanie zapytań online i salonowych, dopytywanie o brakujące dane (`needs_info`), wycena katalogowa i na wymiar (`estimate_quote`, `quote_preview`).
2. **Ochrona marży i cen hurtowni:** robocizna 120 PLN/h, marża 25%, odpad 15%, ceny hurtowni ważne 30 dni (`best_price`).
3. **Bezpieczeństwo magazynowe:** `create_task` z blokadami gwarantuje `stock - reserved >= 0`.
4. **Omnikanałowość:** e-mail, formularz www i tablet w salonie (`web/showroom.html`), który przypisuje lead do salonu (`showroom_name`) i handlowca.
5. **Domykanie sprzedaży:** follow-upy (3. i 7. dzień), ankieta powodów rezygnacji (`lost_reasons`), statusy dla klienta (`status.html`), prośba o opinię Google 7 dni po montażu.

## 3. Guardrails

- Logika decyzyjna i transakcje wyłącznie w PL/pgSQL (RPC).
- Idempotencja: unikalny `external_id` (Message-ID, UUID formularza albo znacznik z salonu), obsługa w `upsert_order`.
- Kwoty `numeric(12,2)`; zaokrąglenie per pozycja, nagłówek to suma pozycji.
- Błędy walidacji (`INVALID_SPEC`, `INVALID_QTY`, `INCOMPLETE_PRODUCT`, `NO_PRICE`, `NO_ITEMS`) dają `needs_review` albo `needs_info`, bez wywracania workflowu.

## 4. Model danych i seed

Materiały (`supabase/seed.sql`) odzwierciedlają asortyment stolarski:

- płyty (`m2`): Płyta laminowana Biała Korpusowa 18 mm, Dąb Halifax Naturalny (Egger), MDF Lakierowany Mat;
- okucia (`szt`): Zawias Blum Clip Top z cichym domykiem, Prowadnica Blum Tandembox;
- obrzeża (`mb`): Obrzeże ABS 2 mm.

`orders.source in ('form','email','showroom')`; kolumny `showroom_name text`, `salesperson_email text`, `customer_name text`.

## 5. MVP a wdrożenie produkcyjne (v2)

| Wąskie gardło | W sprincie | v2 |
|---|---|---|
| Wyceny i zbieracze ofert | `01-order-intake`, `estimate_quote`, `quote_preview`, `09-quote-followup`, `web/showroom.html` | widełki ±10% w `quote_preview` przed pomiarem |
| Rozpiska formatek (BOM) | `product_materials` + wzór m² z 15% odpadu dla customu | `generate_cutlist()` z CSV do e-Rozrys |
| Hurtownie i cenniki | `best_price`, `04-stock-prices`, `08-purchase-orders` | pełne arkusze (`5.796 m2`), `lead_time_days` |
| Zatory na hali | `create_task` z `FOR UPDATE` | bramka zadatku `deposit_paid_at` |
| Montaż u klienta | `03-team-tasks` (linki, Basic Auth) | lista załadunkowa z BOM |
| Ogon zleceń i opinie | `10-status-notify`, `12-review-request` | blokada opinii przy otwartej reklamacji |

## 6. Zakres zadań

1. Schemat, seed, wycena. 2. Magazyn i `best_price`. 3. Przyjmowanie zamówień i parsowanie AI. 4. Zadania zespołu, alerty, import cenników, kolejka wysyłki. 5. Kalkulator, raport bestsellerów. 6. Dokumentacja. 7. Auto-PO. 8. Follow-up i `lost_reasons`. 9. Triage skrzynki. 10. Statusy, `web/status.html`, prośby o opinię. Dodatkowo: salony (`web/showroom.html`, źródło `showroom`), opisane w planie `2026-11-03-salony-i-seed.md`.
