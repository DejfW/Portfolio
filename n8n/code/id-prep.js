// Czyta i waliduje identyfikator z adresu (?order_id=... albo ?task_id=...) lub z formularza.
// Zwraca {valid, id, assignee}. Nic poza poprawnym UUID nie przechodzi dalej.
//@include page
const i = $input.first().json;
const src = Object.assign({}, i.query || {}, i.body && typeof i.body === 'object' ? i.body : {});
// Przeglądarka oznacza żądania z innych witryn nagłówkiem Sec-Fetch-Site: cross-site; formularz z naszej strony to same-origin.
const crossSite = !!(i.body && typeof i.body === 'object' && Object.keys(i.body).length)
  && String((i.headers || {})['sec-fetch-site'] || '').toLowerCase() === 'cross-site';
const id = src.order_id !== undefined ? src.order_id : src.task_id;
const assignee = typeof src.assignee === 'string' ? src.assignee : '';
const valid = isUuid(id) && !crossSite;
return [{ json: { valid, id: valid ? id.toLowerCase() : null, assignee } }];
