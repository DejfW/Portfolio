// Wynik record_lost_reason -> strona dla klienta.
//@include page
const r = $input.first().json;
if (r.ok || r.error === 'ALREADY_ANSWERED') return [{ json: page('Dziękujemy', '<h1 class="ok">Dziękujemy za odpowiedź</h1>') }];
if (r.error === 'ORDER_NOT_LOST' || r.error === 'ORDER_NOT_FOUND') {
  return [{ json: page('Dziękujemy', '<h1>Dziękujemy</h1><p>Ta ankieta nie jest już aktywna.</p>') }];
}
return [{ json: page('Błąd', '<h1 class="err">Nie udało się zapisać odpowiedzi</h1>', 400) }];
