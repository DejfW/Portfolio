// Strona potwierdzenia zakończenia zadania (przycisk wysyła POST, sam link niczego nie zmienia).
//@include page
const p = $input.first().json;
if (!p.valid) return [{ json: page('Błędny link', '<h1 class="err">Nieprawidłowy link</h1>', 400) }];
return [{
  json: page('Zakończ zadanie',
    `<h1>Zakończyć zadanie?</h1><p>Zużyjemy zarezerwowane materiały i powiadomimy klienta, że zamówienie jest gotowe.</p>` +
    `<form method="post" action="/webhook/task-done"><input type="hidden" name="task_id" value="${esc(p.id)}">` +
    `<button type="submit">Zakończ zadanie</button></form>`),
}];
