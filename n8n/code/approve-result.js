// Wynik approve_order -> strona dla właściciela. Powiadomienia Slack (przydział albo braki materiałów)
// powstają już w bazie, w tej samej transakcji co zmiana stanu.
//@include page
const cfg = $('Config POST').first().json;
const r = $input.first().json;

if (r.ok) {
  const doneLink = `${cfg.publicUrl}/webhook/task-done?task_id=${r.task_id}`;
  return [{ json: page('Zlecono',
    `<h1 class="ok">Zlecono zadanie</h1><p>Wykonuje: <b>${esc(r.assignee)}</b><br>Klient: ${esc(r.customer_email)}</p>` +
    `<p>Po wykonaniu zamknij zadanie: <a href="${esc(doneLink)}">${esc(doneLink)}</a></p>`) }];
}

if (r.error === 'INSUFFICIENT_STOCK') {
  const rows = (r.shortages || []).map((s) => {
    const where = s.best_supplier ? `najtaniej: ${s.best_supplier} po ${pln(s.best_price)}` : 'brak aktualnej ceny w hurtowniach';
    return `<li>${esc(s.name)}: brakuje <b>${esc(Number(s.missing))} ${esc(s.unit)}</b> (potrzeba ${esc(Number(s.needed))}, dostępne ${esc(Number(s.available))}), ${esc(where)}</li>`;
  });
  return [{ json: page('Brak materiałów',
    `<h1 class="err">Nie można zlecić: brakuje materiałów</h1><ul>${rows.join('')}</ul><p>Zamówienie czeka na uzupełnienie magazynu.</p>`, 409) }];
}

const labels = { MISSING_ASSIGNEE: 'Wybierz osobę wykonującą zadanie.', INVALID_ASSIGNEE: 'Nieprawidłowa nazwa osoby.',
  ORDER_NOT_FOUND: 'Nie znaleziono zamówienia.', ORDER_NOT_QUOTED: 'Zamówienie nie ma poprawnej wyceny.',
  EMPTY_ORDER: 'Zamówienie nie ma pozycji.' };
const msg = labels[r.error] || (String(r.error || '').startsWith('ORDER_NOT_READY')
  ? 'To zamówienie nie czeka już na zatwierdzenie (jest w realizacji lub zakończone).' : 'Nie udało się zlecić zadania.');
return [{ json: page('Błąd', `<h1 class="err">${esc(msg)}</h1>`, 409) }];
