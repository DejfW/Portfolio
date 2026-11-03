// Kod salonu z adresu (?code=...). Do bazy trafia tylko poprawny kod: małe litery, cyfry i myślniki (3-40 znaków).
const q = $input.first().json.query || {};
const code = typeof q.code === 'string' ? q.code : '';
const valid = /^[a-z0-9-]{3,40}$/.test(code);
return [{ json: { valid, code: valid ? code : '' } }];
