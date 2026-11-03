// Walidacja wejścia webhooka /triage: wiadomość z poczty (external_id = Message-ID, from_email, subject, message).
// Tryb testowy: X-LLM-Mock podmienia odpowiedź AI klasyfikatora, a X-Intake-Mock odpowiedź AI parsera zamówień po
// przekazaniu do intake; oba działają tylko przy ALLOW_LLM_MOCK=1 i nazwie [a-z0-9-]+.
const req = $input.first().json;
const body = req.body && typeof req.body === 'object' ? req.body : {};
const headers = req.headers || {};
const errors = [];
// Endpoint uruchamia model, więc bez INTAKE_TOKEN działa tylko w trybie testowym (ALLOW_LLM_MOCK=1); w produkcji brak sekretu
// zamyka go zamiast otwierać dla wszystkich.
if (req.authorized !== true || (req.tokenSet !== true && req.allowMock !== '1')) errors.push('unauthorized');

const email = typeof body.from_email === 'string' ? body.from_email.trim() : '';
if (email.length > 200 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) errors.push('from_email');
const message = typeof body.message === 'string' ? body.message.trim() : '';
if (!message || message.length > 5000) errors.push('message');
const subject = typeof body.subject === 'string' ? body.subject.replace(/[\u0000-\u001f\u007f]+/g, ' ').trim().slice(0, 300) : '';
if (body.subject !== undefined && body.subject !== null && typeof body.subject !== 'string') errors.push('subject');
const externalId = body.external_id;
// Message-ID bywa dowolnym drukowalnym ASCII bez spacji (np. z "!"); baza zamienia taki klucz na skrót
if (typeof externalId !== 'string' || !/^[\x21-\x7E]{1,500}$/.test(externalId)) errors.push('external_id');

const mockOf = (name) => {
  const raw = headers[name];
  if (raw === undefined || raw === '') return '';
  if (req.allowMock === '1' && typeof raw === 'string' && /^[a-z0-9-]+$/.test(raw)) return raw;
  errors.push(name);
  return '';
};
const mock = mockOf('x-llm-mock');
const intakeMock = mockOf('x-intake-mock');

return [{ json: { valid: errors.length === 0, errors, external_id: externalId, from_email: email, subject, message, mock, intakeMock } }];
