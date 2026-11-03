// Walidacja wejścia webhooka /order. Wejście: pole `body`, `headers` oraz wartości z węzła Config.
const req = $input.first().json;
const body = req.body && typeof req.body === 'object' ? req.body : {};
const headers = req.headers || {};
const errors = [];

// Opcjonalny wspólny sekret (INTAKE_TOKEN): węzeł Config porównuje go z nagłówkiem X-Intake-Token
// i przekazuje tylko wynik, więc sam sekret nie trafia do danych wykonania.
if (req.authorized !== true) errors.push('unauthorized');

const email = typeof body.customer_email === 'string' ? body.customer_email.trim() : '';
if (email.length > 200 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) errors.push('customer_email');

const message = typeof body.message === 'string' ? body.message.trim() : '';
if (!message || message.length > 5000) errors.push('message');

// external_id to klucz idempotencji (Message-ID maila albo UUID z formularza) i jest wymagany:
// bez stabilnego klucza ponowione żądanie utworzyłoby drugie zamówienie.
const externalId = body.external_id;
if (typeof externalId !== 'string' || !/^[A-Za-z0-9._:@<>+=\/-]{1,200}$/.test(externalId)) errors.push('external_id');

let source = 'form';
if (body.source !== undefined && body.source !== null && body.source !== '') {
  if (body.source === 'form' || body.source === 'email') source = body.source;
  else errors.push('source');
}

// Tryb testowy: nagłówek X-LLM-Mock podmienia odpowiedź AI na plik z n8n/fixtures.
// Działa tylko przy ALLOW_LLM_MOCK=1 i nazwie [a-z0-9-]+, a każde inne użycie to błąd 400.
let mock = '';
const rawMock = headers['x-llm-mock'];
if (rawMock !== undefined && rawMock !== '') {
  if (req.allowMock === '1' && typeof rawMock === 'string' && /^[a-z0-9-]+$/.test(rawMock)) mock = rawMock;
  else errors.push('x-llm-mock');
}

return [{
  json: {
    valid: errors.length === 0,
    errors,
    external_id: externalId,
    customer_email: email,
    message,
    source,
    mock,
  },
}];
