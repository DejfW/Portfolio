// Strona potwierdzenia zatwierdzenia zamówienia. Samo wejście w link z maila niczego nie zmienia
// (skanery linków w poczcie otwierają adresy automatycznie), dopiero przycisk wysyła formularz POST.
//@include page
const cfg = $('Config').first().json;
const c = $input.first().json;

if (!c || !c.order_id) return [{ json: page('Nie znaleziono', '<h1 class="err">Nie znaleziono zamówienia</h1>', 404) }];
if (c.status !== 'quoted') {
  return [{ json: page('Zamówienie', `<h1>Zamówienie nie czeka na zatwierdzenie</h1><p>Status: <b>${esc(c.status)}</b></p>`, 200) }];
}
const team = String(cfg.team || '').split(',').map((s) => s.trim()).filter(Boolean);
const options = team.map((n) => `<option>${esc(n)}</option>`).join('');
const lines = ((c.quote && c.quote.lines) || []).map((l) => `<li>${esc(l.label)} × ${esc(l.qty)}</li>`).join('');
return [{
  json: page('Zatwierdź zamówienie',
    `<h1>Zatwierdź zamówienie</h1><p>Klient: <b>${esc(c.customer_email)}</b><br>Wstępna wycena: <b>${esc(pln(c.quote.total))}</b></p>` +
    `<ul>${lines}</ul>` +
    `<form method="post" action="/webhook/approve"><input type="hidden" name="order_id" value="${esc(c.order_id)}">` +
    `<label>Kto wykonuje zadanie?<select name="assignee">${options}</select></label>` +
    `<button type="submit">Zatwierdź i zleć zadanie</button></form>`),
}];
