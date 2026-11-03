// Odpowiedź na nieprawidłowy link (zły albo brakujący identyfikator).
//@include page
return [{ json: page('Błędny link', '<h1 class="err">Nieprawidłowy link</h1><p>Poproś o nowy w wiadomości od systemu.</p>', 400) }];
