# Scenariusz demo (3 minuty)

Przygotowanie: `supabase start`, `scripts/n8n.sh start` (bez mocka, jeśli pokazujesz prawdziwy model), `node scripts/serve-web.mjs`, otwarty Slack `#zamowienia-demo` i skrzynka właściciela.

| Czas | Co pokazujesz | Co mówisz |
|---|---|---|
| 0:00–0:20 | Problem: mail od klienta „potrzebuję komodę z dębu, 120 cm” | Właściciel dostaje takie maile codziennie i wycenia je ręcznie. |
| 0:20–0:55 | `POST /webhook/order` z treścią maila → w bazie zamówienie ze statusem `quoted`, mail z wyceną w kolejce | AI tylko czyta tekst. Cenę liczy funkcja SQL, więc jest powtarzalna i przetestowana. |
| 0:55–1:25 | Link zatwierdzenia (Basic Auth) → status `approved`, rezerwacja materiałów, zadanie dla zespołu na Slacku | Człowiek zatwierdza, a system rezerwuje materiały i przydziela pracę. |
| 1:25–1:50 | Alert o brakach (uchwyt czarny, olej) i raport 7:00 z najtańszą hurtownią | `best_price` bierze tylko ceny nie starsze niż 30 dni. Dąb u Laska jest tańszy, ale po 40 dniach już się nie liczy. |
| 1:50–2:10 | Kalkulator na http://localhost:8080: dodaj komodę, zmień materiał, cena zmienia się na żywo, „Zamawiam” | Publiczne API nie ujawnia kosztów ani marży. Ponowienie żądania nie dubluje zamówienia. |
| 2:10–2:30 | Tablet w salonie (`showroom.html?salon=warszawa-mokotow`): imię, e-mail, zgoda, komoda, „Wyślij wycenę klientowi” → w kolejce mail z wyceną dla klienta i mail do handlowca | Salon identyfikuje token, a handlowca i nazwę salonu zawsze podaje baza. Ten sam formularz bez pozycji zapisuje lead do oddzwonienia. |
| 2:30–2:50 | `POST /webhook/weekly-report` → wiadomość na Slacku z bestsellerami i podsumowaniem AI | Raport liczy baza. Model tylko streszcza, a jego awaria nie psuje raportu. |
| 2:50–3:00 | Testy: `scripts/test-sql.sh` i `scripts/test-calculator.sh` | Każdy element ma testy, a granice systemu opisuje README. |
