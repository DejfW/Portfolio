// Strona potwierdzenia zamówienia do hurtowni. Samo wejście w link niczego nie zmienia (skanery linków w poczcie
// i na Slacku otwierają adresy automatycznie), dopiero przycisk wysyła formularz POST.
//@include page
const c = $input.first().json;

if (!c || !c.po_id) return [{ json: page('Nie znaleziono', '<h1 class="err">Nie znaleziono zamówienia</h1>', 404) }];
if (c.status !== 'draft') {
  return [{ json: page('Zamówienie', `<h1>To zamówienie nie czeka na zatwierdzenie</h1><p>Status: <b>${esc(c.status)}</b></p>`) }];
}
const rows = (c.lines || []).map((l) =>
  `<li>${esc(l.name)}: <b>${esc(Number(l.qty))} ${esc(l.unit)}</b> po ${esc(pln(l.unit_price))}</li>`).join('');
return [{
  json: page('Zatwierdź zamówienie do hurtowni',
    `<h1>Zamówienie do hurtowni</h1><p>Dostawca: <b>${esc(c.supplier)}</b><br>Razem: <b>${esc(pln(c.total))}</b></p><ul>${rows}</ul>` +
    `<form method="post" action="/webhook/po-approve"><input type="hidden" name="po_id" value="${esc(c.po_id)}">` +
    `<button type="submit">Zatwierdź i wyślij do hurtowni</button></form>`),
}];
