// Strona potwierdzenia dostawy (przycisk wysyła POST, sam link niczego nie zmienia).
//@include page
const c = $input.first().json;
if (!c || !c.po_id) return [{ json: page('Nie znaleziono', '<h1 class="err">Nie znaleziono zamówienia</h1>', 404) }];
if (c.status !== 'sent') {
  return [{ json: page('Dostawa', `<h1>Dostawa nie czeka na potwierdzenie</h1><p>Status: <b>${esc(c.status)}</b></p>`) }];
}
const rows = (c.lines || []).map((l) => `<li>${esc(l.name)}: <b>${esc(Number(l.qty))} ${esc(l.unit)}</b></li>`).join('');
return [{
  json: page('Potwierdź dostawę',
    `<h1>Potwierdź dostawę</h1><p>Dostawca: <b>${esc(c.supplier)}</b></p><ul>${rows}</ul>` +
    `<p>Po potwierdzeniu stan magazynu wzrośnie o powyższe ilości.</p>` +
    `<form method="post" action="/webhook/po-received"><input type="hidden" name="po_id" value="${esc(c.po_id)}">` +
    `<button type="submit">Dostawa dotarła w całości</button></form>`),
}];
