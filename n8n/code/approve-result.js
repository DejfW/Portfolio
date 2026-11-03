// Wynik approve_order -> strona dla właściciela i powiadomienia Slack.
// Zwraca jeden element {html, code, notifications:[...]}.
//@include page
const cfg = $('Config').first().json;
const prep = $('Parse approve').first().json;
const r = $input.first().json;
const day = new Date().toISOString().slice(0, 10);

if (r.ok) {
  const doneLink = `${cfg.publicUrl}/webhook/task-done?task_id=${r.task_id}`;
  const p = page('Zlecono',
    `<h1 class="ok">Zlecono zadanie</h1><p>Wykonuje: <b>${esc(r.assignee)}</b><br>Klient: ${esc(r.customer_email)}</p>` +
    `<p>Po wykonaniu zamknij zadanie: <a href="${esc(doneLink)}">${esc(doneLink)}</a></p>`);
  return [{ json: { ...p, notifications: [{ channel: 'slack', kind: 'task_assigned', dedupe_key: `task:${r.task_id}`,
    text: `🛠️ Nowe zadanie dla *${slackEsc(r.assignee)}*\nKlient: ${slackEsc(r.customer_email)}\nWycena: ${pln(r.total)}\nPo wykonaniu zamknij zadanie: ${doneLink}` }] } }];
}

if (r.error === 'INSUFFICIENT_STOCK') {
  const rows = (r.shortages || []).map((s) => {
    const where = s.best_supplier ? `najtaniej: ${s.best_supplier} po ${pln(s.best_price)}` : 'brak aktualnej ceny w hurtowniach';
    return { text: `• ${s.name}: brakuje ${Number(s.missing)} ${s.unit} (potrzeba ${Number(s.needed)}, dostępne ${Number(s.available)}), ${where}`,
      html: `<li>${esc(s.name)}: brakuje <b>${esc(Number(s.missing))} ${esc(s.unit)}</b> (potrzeba ${esc(Number(s.needed))}, dostępne ${esc(Number(s.available))}), ${esc(where)}</li>` };
  });
  const p = page('Brak materiałów', `<h1 class="err">Nie można zlecić: brakuje materiałów</h1><ul>${rows.map((x) => x.html).join('')}</ul><p>Zamówienie czeka na uzupełnienie magazynu.</p>`, 409);
  return [{ json: { ...p, notifications: [{ channel: 'slack', kind: 'stock_shortage', dedupe_key: `shortage:${prep.id}:${day}`,
    text: `⚠️ Brakuje materiałów dla zamówienia ${prep.id}:\n${rows.map((x) => x.text).join('\n')}` }] } }];
}

const labels = { MISSING_ASSIGNEE: 'Wybierz osobę wykonującą zadanie.', INVALID_ASSIGNEE: 'Nieprawidłowa nazwa osoby.',
  ORDER_NOT_FOUND: 'Nie znaleziono zamówienia.', ORDER_NOT_QUOTED: 'Zamówienie nie ma poprawnej wyceny.',
  EMPTY_ORDER: 'Zamówienie nie ma pozycji.' };
const msg = labels[r.error] || (String(r.error || '').startsWith('ORDER_NOT_READY') ? 'To zamówienie nie czeka już na zatwierdzenie (jest w realizacji lub zakończone).' : 'Nie udało się zlecić zadania.');
return [{ json: { ...page('Błąd', `<h1 class="err">${esc(msg)}</h1>`, 409), notifications: [] } }];
