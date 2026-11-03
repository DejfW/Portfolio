// Strona ankiety (GET). Samo wejście w link niczego nie zapisuje (skanery linków w poczcie otwierają adresy
// automatycznie), powód zapisuje dopiero kliknięcie przycisku (POST). Strona nie ujawnia nic poza statusem ankiety.
//@include page
const t = $('Lost prep').first().json.token;
const c = $input.first().json;
if (!c || c.status !== 'lost') {
  return [{ json: page('Dziękujemy', '<h1>Dziękujemy</h1><p>Ta ankieta nie jest już aktywna.</p>') }];
}
if (c.answered) return [{ json: page('Dziękujemy', '<h1 class="ok">Dziękujemy za odpowiedź</h1>') }];
const btn = (value, label) => `<p><button type="submit" name="reason" value="${value}">${label}</button></p>`;
return [{
  json: page('Dlaczego zrezygnowali Państwo z wyceny?',
    `<h1>Dlaczego zrezygnowali Państwo z wyceny?</h1><form method="post" action="/webhook/lost-reason">` +
    `<input type="hidden" name="token" value="${esc(t)}">` +
    btn('price', 'Cena') + btn('time', 'Termin realizacji') + btn('other_offer', 'Wybrali Państwo inną ofertę') + btn('other', 'Inny powód') +
    `</form>`),
}];
