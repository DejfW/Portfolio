// Wynik task_done -> strona oraz powiadomienia (mail do klienta i wiadomość Slack).
//@include page
const prep = $('Parse done').first().json;
const r = $input.first().json;

if (r.ok) {
  const p = page('Zakończono', `<h1 class="ok">Zadanie zakończone</h1><p>Klient dostanie informację, że zamówienie jest gotowe.</p>`);
  return [{ json: { ...p, notifications: [
    { channel: 'email', order_id: r.order_id, kind: 'order_done', to: r.customer_email,
      subject: 'Twoje zamówienie jest gotowe',
      body: 'Dzień dobry,\n\nz przyjemnością informujemy, że Twoje zamówienie jest gotowe. Skontaktujemy się w sprawie odbioru lub dostawy.\n\nPozdrawiamy,\nStolarnia' },
    { channel: 'slack', kind: 'task_done', dedupe_key: `done:${prep.id}`,
      text: `✅ ${slackEsc(r.assignee)} zakończył(a) zadanie dla ${slackEsc(r.customer_email)}. Klient dostanie informację.` },
  ] } }];
}
const msg = r.error === 'TASK_ALREADY_DONE' ? 'To zadanie jest już zakończone.' : r.error === 'TASK_NOT_FOUND' ? 'Nie znaleziono zadania.' : 'Nie udało się zakończyć zadania.';
return [{ json: { ...page('Błąd', `<h1 class="err">${esc(msg)}</h1>`, 409), notifications: [] } }];
