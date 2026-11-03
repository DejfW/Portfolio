// Czyta i waliduje identyfikator z adresu (?order_id=... albo ?task_id=...) lub z formularza.
// Zwraca {valid, id, assignee}. Nic poza poprawnym UUID nie przechodzi dalej.
//@include page
const i = $input.first().json;
const src = Object.assign({}, i.query || {}, i.body && typeof i.body === 'object' ? i.body : {});
const id = src.order_id !== undefined ? src.order_id : src.task_id;
const assignee = typeof src.assignee === 'string' ? src.assignee : '';
return [{ json: { valid: isUuid(id), id: isUuid(id) ? id.toLowerCase() : null, assignee } }];
