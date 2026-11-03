// Przygotowuje przekazanie wiadomości do workflow 01 (POST /webhook/order): ten sam external_id, więc ponowienie
// jest idempotentne. Atrapa AI parsera (tylko tryb testowy) pochodzi z nagłówka X-Intake-Mock pierwotnego żądania.
let mock = '';
for (const name of ['Triage normalize', 'Sweep params']) {
  try { const v = $(name).first().json.intakeMock; if (typeof v === 'string' && v) { mock = v; break; } } catch (e) { /* węzeł nie był uruchomiony */ }
}
const base = String($env.PUBLIC_URL || 'http://localhost:5678').replace(/\/+$/, '');
// naprawa zwraca wiele wiadomości naraz: każda dostaje własny ładunek
// Limit /order to 5000 znaków treści. Treść wiadomości nigdy nie jest skracana na rzecz tematu: temat dopisujemy tylko wtedy,
// gdy mieści się w limicie. Cięcie po punktach kodowych (nie jednostkach UTF-16) nie rozrywa emoji, bo samotny surogat
// jest odrzucany przez Postgresa i taka wiadomość nigdy nie trafiłaby do intake.
const cut = (t, n) => Array.from(String(t)).slice(0, n).join('');
const len = (t) => Array.from(String(t)).length;
return $input.all().map(({ json: m }) => {
  const prefix = m.subject ? `Temat: ${m.subject}\n\n` : '';
  const body = cut(m.body, 5000);
  const message = len(prefix) + len(body) <= 5000 ? prefix + body : body;
  return { json: { inbox_id: m.id, url: `${base}/webhook/order`, mock,
    payload: { external_id: m.external_id, customer_email: m.from_email, source: 'email', message } } };
});
