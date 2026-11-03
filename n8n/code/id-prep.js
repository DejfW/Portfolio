// Czyta i waliduje identyfikator z adresu (?order_id=..., ?task_id=... albo ?po_id=...) dla stron otwieranych linkiem (GET).
// Zwraca {valid, id}. Nic poza poprawnym UUID nie przechodzi dalej. Żądania zmieniające stan (POST) obsługuje id-prep-post.
//@include page
const i = $input.first().json;
const q = i.query || {};
const id = q.order_id !== undefined ? q.order_id : (q.task_id !== undefined ? q.task_id : q.po_id);
const valid = isUuid(id);
return [{ json: { valid, id: valid ? id.toLowerCase() : null } }];
