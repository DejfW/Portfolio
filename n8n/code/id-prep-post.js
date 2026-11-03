// Walidacja formularza POST (zmiana stanu): identyfikator tylko z treści formularza, nigdy z adresu.
// Kontrola pochodzenia dotyczy każdego POST, także z pustą treścią. Strony n8n są serwowane w piaskownicy CSP,
// więc prawdziwy formularz wysyła Origin: null (i Sec-Fetch-Site: cross-site); odrzucamy tylko żądania z Origin
// innej witryny. Ochroną przed obcym formularzem są też logowanie Basic i nieodgadnialny UUID w treści.
//@include page
const i = $input.first().json;
const h = i.headers || {};
const body = i.body && typeof i.body === 'object' ? i.body : {};
const origin = String(h.origin || '').trim().toLowerCase();
const host = String(h['x-forwarded-host'] || h.host || '').trim().toLowerCase();
const sameOrigin = origin === '' || origin === 'null' || origin.replace(/^https?:\/\//, '') === host;
const id = body.order_id !== undefined ? body.order_id : (body.task_id !== undefined ? body.task_id : body.po_id);
const assignee = typeof body.assignee === 'string' ? body.assignee : '';
const valid = isUuid(id) && sameOrigin;
return [{ json: { valid, id: valid ? id.toLowerCase() : null, assignee } }];
