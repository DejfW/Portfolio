// Wynik task_done -> strona. Mail dla klienta i wiadomość Slack zapisuje już baza, w tej samej transakcji.
//@include page
const r = $input.first().json;
if (r.ok) {
  return [{ json: page('Zakończono', '<h1 class="ok">Zadanie zakończone</h1><p>Klient dostanie informację, że zamówienie jest gotowe.</p>') }];
}
const msg = r.error === 'TASK_ALREADY_DONE' ? 'To zadanie jest już zakończone.'
  : r.error === 'TASK_NOT_FOUND' ? 'Nie znaleziono zadania.' : 'Nie udało się zakończyć zadania.';
return [{ json: page('Błąd', `<h1 class="err">${esc(msg)}</h1>`, 409) }];
