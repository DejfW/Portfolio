// Wynik receive_delivery -> strona.
//@include page
const r = $input.first().json;
if (r.ok) return [{ json: page('Przyjęto', '<h1 class="ok">Dostawa przyjęta</h1><p>Stan magazynu został zwiększony.</p>') }];
const labels = { PO_NOT_FOUND: 'Nie znaleziono zamówienia.', PO_NOT_SENT: 'Tej dostawy nie można przyjąć (zamówienie nie jest wysłane albo już przyjęte).' };
return [{ json: page('Błąd', `<h1 class="err">${esc(labels[r.error] || 'Nie udało się przyjąć dostawy.')}</h1>`, 409) }];
