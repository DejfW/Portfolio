import test from 'node:test';
import assert from 'node:assert/strict';
import { runCode } from './harness.mjs';

const cfg = { publicUrl: 'http://x', team: 'Jan, Anna ,Piotr' };
const ID = '11111111-2222-3333-4444-555555555555';

test('id-prep (GET) przepuszcza tylko poprawny UUID z adresu', () => {
  const ok = runCode('id-prep', { input: [{ query: { order_id: ID.toUpperCase() } }] })[0];
  assert.deepEqual([ok.valid, ok.id], [true, ID]);
  for (const bad of [undefined, '', 'abc', `${ID}'; drop`, ID + 'x', ['x'], { a: 1 }]) {
    const r = runCode('id-prep', { input: [{ query: { order_id: bad } }] })[0];
    assert.equal(r.valid, false, `id: ${JSON.stringify(bad)}`);
    assert.equal(r.id, null);
  }
  assert.equal(runCode('id-prep', { input: [{}] })[0].valid, false);
});

test('id-prep-post: identyfikator tylko z formularza, kontrola Origin dla każdego POST', () => {
  const post = (over) => runCode('id-prep-post', { input: [{ query: {}, headers: { host: 'localhost:5678' }, body: { task_id: ID, assignee: 'Jan' }, ...over }] })[0];
  const form = post({});
  assert.deepEqual([form.valid, form.id, form.assignee], [true, ID, 'Jan']);
  // strona n8n jest w piaskownicy CSP: prawdziwy formularz wysyła Origin: null i Sec-Fetch-Site: cross-site
  assert.equal(post({ headers: { host: 'localhost:5678', origin: 'null', 'sec-fetch-site': 'cross-site' } }).valid, true);
  assert.equal(post({ headers: { host: 'localhost:5678', origin: 'http://localhost:5678' } }).valid, true);
  assert.equal(post({ headers: { host: 'localhost:5678', origin: 'https://evil.example' } }).valid, false);
  // pusty POST z identyfikatorem tylko w adresie nie przechodzi (także z obcego Origin)
  assert.equal(post({ query: { order_id: ID }, body: {} }).valid, false);
  assert.equal(post({ query: { order_id: ID }, body: {}, headers: { host: 'x', origin: 'https://evil.example' } }).valid, false);
  assert.equal(post({ query: { order_id: ID }, body: { order_id: 'zly' } }).valid, false);
});

const ctx = (over = {}) => ({ order_id: ID, status: 'quoted', customer_email: 'k@example.com',
  quote: { total: 1266.5, lines: [{ label: 'Szafka', qty: 2 }] }, ...over });

test('strona zatwierdzenia: formularz POST z listą zespołu, a link GET niczego nie zmienia', () => {
  const [r] = runCode('approve-page', { nodes: { Config: cfg }, input: [ctx()] });
  assert.equal(r.code, 200);
  assert.match(r.html, /<form method="post" action="\/webhook\/approve">/);
  assert.match(r.html, /<option>Jan<\/option><option>Anna<\/option><option>Piotr<\/option>/);
  assert.match(r.html, /1266,50 zł/);
  assert.ok(r.html.includes(`value="${ID}"`));
});

test('strona zatwierdzenia escapuje dane klienta (XSS)', () => {
  const [r] = runCode('approve-page', { nodes: { Config: cfg }, input: [ctx({ customer_email: '"><script>alert(1)</script>@x.pl', quote: { total: 1, lines: [{ label: '<img src=x onerror=alert(1)>', qty: 1 }] } })] });
  assert.ok(!r.html.includes('<script>'), 'brak niepoprawnie wstawionego skryptu');
  assert.ok(!r.html.includes('<img src=x'), 'brak niepoprawnie wstawionego znacznika');
  assert.match(r.html, /&lt;script&gt;/);
});

test('strona zatwierdzenia: brak zamówienia i zły status nie pokazują formularza', () => {
  assert.equal(runCode('approve-page', { nodes: { Config: cfg }, input: [{}] })[0].code, 404);
  const [r] = runCode('approve-page', { nodes: { Config: cfg }, input: [ctx({ status: 'in_progress' })] });
  assert.ok(!r.html.includes('<form'));
  assert.match(r.html, /in_progress/);
});

const approve = (result) => runCode('approve-result', { nodes: { 'Config POST': cfg }, input: [result] })[0];

test('udane zatwierdzenie: strona z wykonawcą i linkiem do zakończenia zadania', () => {
  const r = approve({ ok: true, task_id: 'T1', order_id: ID, assignee: 'Jan', customer_email: 'k@example.com', total: 700 });
  assert.equal(r.code, 200);
  assert.match(r.html, /Zlecono zadanie/);
  assert.match(r.html, /\/webhook\/task-done\?task_id=T1/);
  assert.ok(!('notifications' in r), 'powiadomienia zapisuje baza, nie n8n');
});

test('brak materiału: strona 409 z listą braków i najtańszą hurtownią, bez surowego HTML', () => {
  const r = approve({ ok: false, error: 'INSUFFICIENT_STOCK', shortages: [
    { name: 'Płyta <b>dąb</b>', unit: 'm2', needed: 5, available: 3, missing: 2, best_supplier: 'MebloHurt', best_price: 205 },
    { name: 'Olej', unit: 'l', needed: 1, available: 0, missing: 1, best_supplier: null, best_price: null }] });
  assert.equal(r.code, 409);
  assert.match(r.html, /Płyta &lt;b&gt;dąb&lt;\/b&gt;: brakuje <b>2 m2<\/b>/);
  assert.match(r.html, /najtaniej: MebloHurt po 205,00 zł/);
  assert.match(r.html, /Olej: brakuje <b>1 l<\/b>.*brak aktualnej ceny/);
  assert.ok(!r.html.includes('<b>dąb</b>'));
});

test('błędy zatwierdzenia dają stronę 409', () => {
  for (const error of ['ORDER_NOT_READY:in_progress', 'MISSING_ASSIGNEE', 'ORDER_NOT_FOUND', 'COS_NIEZNANEGO']) {
    assert.equal(approve({ ok: false, error }).code, 409, error);
  }
  assert.match(approve({ ok: false, error: 'ORDER_NOT_READY:done' }).html, /nie czeka już na zatwierdzenie/);
});

test('zakończenie zadania: strona sukcesu, a powtórka to komunikat 409', () => {
  const run = (r) => runCode('done-result', { input: [r] })[0];
  const ok = run({ ok: true, order_id: ID, assignee: 'Jan', customer_email: 'k@example.com' });
  assert.equal(ok.code, 200);
  assert.match(ok.html, /Zadanie zakończone/);
  const again = run({ ok: false, error: 'TASK_ALREADY_DONE' });
  assert.equal(again.code, 409);
  assert.match(again.html, /już zakończone/);
});

test('GET z linku z innej witryny jest dozwolony, a POST z obcym Origin odrzucony', () => {
  // link w mailu lub na Slacku otwiera się z innej witryny (Sec-Fetch-Site: cross-site), więc GET nie jest blokowany
  const get = runCode('id-prep', { input: [{ query: { order_id: ID }, headers: { 'sec-fetch-site': 'cross-site' } }] })[0];
  assert.equal(get.valid, true);
  const post = (origin) => runCode('id-prep-post', { input: [{ query: {}, body: { order_id: ID, assignee: 'Jan' }, headers: { host: 'h:5678', ...(origin ? { origin } : {}) } }] })[0];
  assert.equal(post(undefined).valid, true);          // curl i skrypty nie wysyłają Origin
  assert.equal(post('null').valid, true);             // formularz ze strony n8n w piaskownicy CSP
  assert.equal(post('http://h:5678').valid, true);
  const cross = post('https://evil.example');
  assert.deepEqual([cross.valid, cross.id], [false, null]);
});

test('bad-link zwraca stronę 400', () => {
  const [r] = runCode('bad-link');
  assert.equal(r.code, 400);
  assert.match(r.html, /Nieprawidłowy link/);
});
