// Wynik approve_purchase_order -> strona. Mail do hurtowni zapisuje już baza, w tej samej transakcji.
//@include page
const cfg = $('Config POST approve').first().json;
const r = $input.first().json;
if (r.ok) {
  const link = `${cfg.publicUrl}/webhook/po-received?po_id=${r.po_id}`;
  return [{ json: page('Wysłano',
    `<h1 class="ok">Zamówienie wysłane</h1><p>Hurtownia: <b>${esc(r.supplier)}</b>, razem ${esc(pln(r.total))}.</p>` +
    `<p>Gdy dostawa dotrze, potwierdź ją tutaj: <a href="${esc(link)}">${esc(link)}</a></p>`) }];
}
const labels = { PO_NOT_FOUND: 'Nie znaleziono zamówienia.', PO_NOT_DRAFT: 'To zamówienie zostało już zatwierdzone lub anulowane.',
  SUPPLIER_NO_EMAIL: 'Hurtownia nie ma adresu e-mail, uzupełnij go w bazie.' };
return [{ json: page('Błąd', `<h1 class="err">${esc(labels[r.error] || 'Nie udało się zatwierdzić zamówienia.')}</h1>`, 409) }];
