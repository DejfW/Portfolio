// Ostatni krok łańcuchów POST: strona z wyniku tej gałęzi, która się wykonała (zatwierdzenie albo zakończenie).
// Błąd zapisu powiadomień nie ukrywa wyniku operacji, która już się udała.
const src = (() => {
  try { return $('Approve result').first().json; } catch (e) { return $('Done result').first().json; }
})();
return [{ json: { html: src.html, code: src.code } }];
