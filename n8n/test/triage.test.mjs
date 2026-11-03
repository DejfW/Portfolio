import test from 'node:test';
import assert from 'node:assert/strict';
import { runCode } from './harness.mjs';

const norm = (body, over = {}) => runCode('triage-normalize', { input: [{ authorized: true, tokenSet: true, allowMock: '1', headers: {}, body, ...over }] })[0];
const good = { external_id: '<abc@mail.example>', from_email: 'k@example.com', subject: 'Pytanie', message: 'Ile trwa realizacja?' };

test('triage-normalize: poprawna wiadomość i odrzucenia', () => {
  const ok = norm(good);
  assert.equal(ok.valid, true);
  assert.deepEqual([ok.external_id, ok.from_email, ok.subject], ['<abc@mail.example>', 'k@example.com', 'Pytanie']);
  assert.ok(norm({ ...good, subject: 'A\r\nBcc: x@y.z' }).subject.indexOf('\n') < 0, 'subject bez nowych linii');
  for (const [field, bad] of [['external_id', 'zły id'], ['external_id', 'a'.repeat(501)], ['external_id', undefined], ['from_email', 'nie-mail'], ['message', ''], ['message', 'x'.repeat(5001)], ['subject', 5]]) {
    const r = norm({ ...good, [field]: bad });
    assert.equal(r.valid, false, field);
    assert.ok(r.errors.includes(field), `${field}: ${r.errors}`);
  }
  assert.equal(norm(good, { authorized: false }).valid, false);
  assert.equal(norm({ ...good, external_id: '<invoice!123@example.com>' }).valid, true, 'poprawny Message-ID z wykrzyknikiem');
  assert.equal(norm(undefined).valid, false);
});

test('triage-normalize: bez INTAKE_TOKEN endpoint działa tylko w trybie testowym (produkcja zamyka się, nie otwiera)', () => {
  assert.equal(norm(good, { tokenSet: false, allowMock: '1' }).valid, true);
  const prod = norm(good, { tokenSet: false, allowMock: '0' });
  assert.equal(prod.valid, false);
  assert.ok(prod.errors.includes('unauthorized'));
  assert.equal(norm(good, { tokenSet: true, allowMock: '0' }).valid, true);
});

test('triage-normalize: atrapy AI tylko w trybie testowym i tylko poprawne nazwy', () => {
  const h = (headers, allowMock = '1') => norm(good, { headers, allowMock });
  assert.deepEqual([h({ 'x-llm-mock': 'triage-order', 'x-intake-mock': 'catalog' }).mock, h({ 'x-intake-mock': 'catalog' }).intakeMock], ['triage-order', 'catalog']);
  assert.equal(h({ 'x-llm-mock': 'triage-order' }, '0').valid, false);
  assert.equal(h({ 'x-intake-mock': '../x' }).valid, false);
});

test('triage-prompt: FAQ, temat i treść wstawione, znaki sterujące usunięte', () => {
  const [p] = runCode('triage-prompt', {
    nodes: { 'Triage normalize': { subject: 'Temat', message: 'Treść\u0000 z \u0007 śmieciami', mock: 'm' }, Config: { projectDir: '/p' } },
  });
  assert.match(p.prompt, /FAQ-TEKST/);
  assert.ok(p.prompt.includes('Treść  z   śmieciami'), p.prompt);
  assert.ok(!/[\u0000\u0007]/.test(p.prompt));
  assert.deepEqual([p.mock, p.projectDir], ['m', '/p']);
});

const validate = (text) => runCode('triage-validate', { nodes: { Receive: { inbox_id: 'i-1' } }, input: [{ text }] })[0];

test('triage-prompt: znaczniki w temacie nie rozwijają się ponownie (limit rozmiaru promptu)', () => {
  const [p] = runCode('triage-prompt', { nodes: { 'Triage normalize': { subject: '{{MESSAGE}}'.repeat(27), message: 'M'.repeat(5000), mock: '' }, Config: { projectDir: '/p' } } });
  assert.ok(p.prompt.length < 9000, `prompt ${p.prompt.length} znaków`);
  assert.equal(p.prompt.split('M'.repeat(5000)).length - 1, 1, 'treść tylko raz');
});

test('triage-validate: poprawny JSON (także w bloku kodu) przechodzi, śmieci dają pusty obiekt', () => {
  assert.deepEqual(validate('{"category":"question","confidence":0.9,"reply_draft":"Odp."}'),
    { inbox_id: 'i-1', p: { category: 'question', confidence: 0.9, reply_draft: 'Odp.' } });
  assert.equal(validate('```json\n{"category":"order","confidence":1}\n```').p.category, 'order');
  for (const bad of ['', 'Przepraszam, nie mogę', '{niepoprawny', '[1,2]', 'null', '{"category":5,"confidence":"x"}']) {
    assert.deepEqual(validate(bad).p, {}, JSON.stringify(bad));
  }
  assert.equal(validate('{"confidence":NaN}').p.confidence, undefined);
});

test('triage-forward-prep: ładunek dla intake z tym samym external_id, tematem w treści i atrapą z pierwotnego żądania', () => {
  const row = { id: 'i-1', external_id: '<a@b>', from_email: 'k@example.com', subject: 'Temat', body: 'Chcę komodę' };
  const [o] = runCode('triage-forward-prep', { input: [row], nodes: { 'Triage normalize': { intakeMock: 'catalog' } }, env: { PUBLIC_URL: 'http://x:5678/' } });
  assert.equal(o.url, 'http://x:5678/webhook/order');
  assert.deepEqual(o.payload, { external_id: '<a@b>', customer_email: 'k@example.com', source: 'email', message: 'Temat: Temat\n\nChcę komodę' });
  assert.equal(o.mock, 'catalog');
  const [s] = runCode('triage-forward-prep', { input: [{ ...row, subject: '' }], nodes: { 'Sweep params': { intakeMock: '' } }, env: {} });
  assert.equal(s.mock, '');
  assert.equal(s.url, 'http://localhost:5678/webhook/order');
  assert.equal(s.payload.message, 'Chcę komodę');
  assert.equal(runCode('triage-forward-prep', { input: [{ ...row, body: 'x'.repeat(9000) }], env: {} })[0].payload.message.length, 5000);
  // naprawa zwraca kilka wiadomości: wszystkie dostają ładunek, nie tylko pierwsza
  // koniec zamówienia przy długiej treści z tematem nie ginie, a emoji na granicy limitu nie jest rozrywane
  const tail = runCode('triage-forward-prep', { input: [{ ...row, subject: 'T', body: 'a'.repeat(4980) + 'ZAMAWIAM STÓŁ' }], env: {} })[0].payload.message;
  assert.ok(tail.endsWith('ZAMAWIAM STÓŁ') && tail.length <= 5000, 'cała treść zachowana');
  const emoji = runCode('triage-forward-prep', { input: [{ ...row, subject: '', body: 'a'.repeat(4999) + '😀' }], env: {} })[0].payload.message;
  assert.equal(Array.from(emoji).length, 5000);
  assert.doesNotMatch(emoji, /[\ud800-\udbff](?![\udc00-\udfff])/, 'brak samotnego surogatu');
  const many = runCode('triage-forward-prep', { input: [row, { ...row, id: 'i-2', external_id: '<c@d>' }], env: {} });
  assert.deepEqual(many.map((x) => [x.inbox_id, x.payload.external_id]), [['i-1', '<a@b>'], ['i-2', '<c@d>']]);
});

test('triage-sweep-params: harmonogram zawsze, webhook tylko w trybie testowym', () => {
  const run = (i) => runCode('triage-sweep-params', { input: [i] })[0];
  assert.equal(run({ allowMock: '0' }).allowed, true);
  assert.equal(run({ headers: {}, allowMock: '0' }).allowed, false);
  assert.equal(run({ headers: { 'x-intake-mock': 'catalog' }, allowMock: '1' }).intakeMock, 'catalog');
  assert.equal(run({ headers: { 'x-intake-mock': '../x' }, allowMock: '1' }).allowed, false);
});
