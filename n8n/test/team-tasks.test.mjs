import test from 'node:test';
import assert from 'node:assert/strict';
import { runCode } from './harness.mjs';

const cfg = { publicUrl: 'http://x', team: 'Jan, Anna ,Piotr' };
const ID = '11111111-2222-3333-4444-555555555555';

test('id-prep przepuszcza tylko poprawny UUID z adresu lub formularza', () => {
  const ok = runCode('id-prep', { input: [{ query: { order_id: ID.toUpperCase() } }] })[0];
  assert.deepEqual([ok.valid, ok.id], [true, ID]);
  const form = runCode('id-prep', { input: [{ query: {}, body: { task_id: ID, assignee: 'Jan' } }] })[0];
  assert.deepEqual([form.valid, form.id, form.assignee], [true, ID, 'Jan']);
  for (const bad of [undefined, '', 'abc', `${ID}'; drop`, ID + 'x', ['x'], { a: 1 }]) {
    const r = runCode('id-prep', { input: [{ query: { order_id: bad } }] })[0];
    assert.equal(r.valid, false, `id: ${JSON.stringify(bad)}`);
    assert.equal(r.id, null);
  }
  assert.equal(runCode('id-prep', { input: [{}] })[0].valid, false);
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

const approve = (result) => runCode('approve-result', { nodes: { Config: cfg, 'Parse approve': { id: ID } }, input: [result] })[0];

test('udane zatwierdzenie: Slack z przydziałem i linkiem do zakończenia', () => {
  const r = approve({ ok: true, task_id: 'T1', order_id: ID, assignee: 'Jan', customer_email: 'k@example.com', total: 700 });
  assert.equal(r.code, 200);
  const n = r.notifications[0];
  assert.deepEqual([n.channel, n.kind, n.dedupe_key], ['slack', 'task_assigned', 'task:T1']);
  assert.match(n.text, /\*Jan\*/);
  assert.match(n.text, /700,00 zł/);
  assert.match(n.text, /\/webhook\/task-done\?task_id=T1/);
});

test('brak materiału: lista braków z najtańszą hurtownią, status 409 i alert Slack', () => {
  const r = approve({ ok: false, error: 'INSUFFICIENT_STOCK', shortages: [
    { name: 'Płyta dąb', unit: 'm2', needed: 5, available: 3, missing: 2, best_supplier: 'MebloHurt', best_price: 205 },
    { name: 'Olej', unit: 'l', needed: 1, available: 0, missing: 1, best_supplier: null, best_price: null }] });
  assert.equal(r.code, 409);
  const t = r.notifications[0].text;
  assert.match(t, /Płyta dąb: brakuje 2 m2/);
  assert.match(t, /najtaniej: MebloHurt po 205,00 zł/);
  assert.match(t, /Olej: brakuje 1 l.*brak aktualnej ceny/);
  assert.match(r.notifications[0].dedupe_key, new RegExp(`^shortage:${ID}:\\d{4}-\\d{2}-\\d{2}$`));
});

test('błędy zatwierdzenia nie wysyłają powiadomień', () => {
  for (const error of ['ORDER_NOT_READY:in_progress', 'MISSING_ASSIGNEE', 'ORDER_NOT_FOUND', 'COS_NIEZNANEGO']) {
    const r = approve({ ok: false, error });
    assert.equal(r.code, 409);
    assert.deepEqual(r.notifications, []);
  }
});

test('zakończenie zadania: mail do klienta i Slack, a powtórka to tylko komunikat', () => {
  const run = (r) => runCode('done-result', { nodes: { 'Parse done': { id: 'T1' } }, input: [r] })[0];
  const ok = run({ ok: true, order_id: ID, assignee: 'Jan', customer_email: 'k@example.com' });
  assert.deepEqual(ok.notifications.map((n) => n.channel + ':' + n.kind), ['email:order_done', 'slack:task_done']);
  assert.equal(ok.notifications[0].to, 'k@example.com');
  assert.equal(ok.notifications[1].dedupe_key, 'done:T1');
  const again = run({ ok: false, error: 'TASK_ALREADY_DONE' });
  assert.equal(again.code, 409);
  assert.deepEqual(again.notifications, []);
});

test('Slack: dane od klienta są escapowane (&, <, >)', () => {
  const r = approve({ ok: true, task_id: 'T1', order_id: ID, assignee: 'Jan <!channel>', customer_email: 'a&b@x.pl', total: 1 });
  assert.ok(!r.notifications[0].text.includes('<!channel>'));
  assert.match(r.notifications[0].text, /&lt;!channel&gt;/);
  assert.match(r.notifications[0].text, /a&amp;b@x\.pl/);
});

test('final-page bierze wynik gałęzi, która się wykonała', () => {
  const a = runCode('final-page', { nodes: { 'Approve result': { html: 'A', code: 200 } }, input: [{ queued: 1 }] });
  assert.deepEqual(a, [{ html: 'A', code: 200 }]);
  const d = runCode('final-page', { nodes: { 'Done result': { html: 'D', code: 409 } }, input: [{}] });
  assert.deepEqual(d, [{ html: 'D', code: 409 }]);
});

test('bad-link zwraca stronę 400', () => {
  const [r] = runCode('bad-link');
  assert.equal(r.code, 400);
  assert.match(r.html, /Nieprawidłowy link/);
});
