// Ankieta powodów rezygnacji: token zamówienia z adresu (GET) albo z formularza (POST) i wybrany powód.
//@include page
const i = $input.first().json;
const q = i.query || {};
const b = i.body && typeof i.body === 'object' ? i.body : {};
const isPost = Object.keys(b).length > 0;
const token = isPost ? b.token : q.token;
const reason = typeof b.reason === 'string' ? b.reason : '';
const valid = isUuid(token) && (!isPost || ['price', 'time', 'other_offer', 'other'].includes(reason));
return [{ json: { valid, token: valid ? token.toLowerCase() : null, reason: valid ? reason : '' } }];
