import test from 'node:test';
import assert from 'node:assert/strict';
import { runCode } from './harness.mjs';

const ID = '11111111-2222-3333-4444-555555555555';
const po = (over = {}) => ({ po_id: ID, status: 'draft', supplier: 'Hurt A', total: 361,
  lines: [{ name: 'Mat 1', unit: 'm2', qty: 18, unit_price: 10 }, { name: 'Mat 2', unit: 'szt', qty: 5, unit_price: 3.5 }], ...over });

test('id-prep i id-prep-post przyjmują po_id (GET z adresu, POST z formularza)', () => {
  const get = runCode('id-prep', { input: [{ query: { po_id: ID } }] })[0];
  assert.deepEqual([get.valid, get.id], [true, ID]);
  const post = runCode('id-prep-post', { input: [{ query: {}, headers: { host: 'h' }, body: { po_id: ID.toUpperCase() } }] })[0];
  assert.deepEqual([post.valid, post.id], [true, ID]);
  assert.equal(runCode('id-prep', { input: [{ query: { po_id: `${ID}'; drop` } }] })[0].valid, false);
});

test('po-params: harmonogram zawsze, webhook tylko w trybie testowym', () => {
  assert.equal(runCode('po-params', { input: [{ allowMock: '0' }] })[0].allowed, true);
  assert.equal(runCode('po-params', { input: [{ headers: {}, allowMock: '0' }] })[0].allowed, false);
  assert.equal(runCode('po-params', { input: [{ headers: {}, allowMock: '1' }] })[0].allowed, true);
});

test('strona zatwierdzenia PO: formularz POST z pozycjami i sumą', () => {
  const [r] = runCode('po-approve-page', { input: [po()] });
  assert.equal(r.code, 200);
  assert.match(r.html, /<form method="post" action="\/webhook\/po-approve">/);
  assert.match(r.html, /Mat 1/);
  assert.match(r.html, /361,00 zł/);
  assert.ok(r.html.includes(`value="${ID}"`));
});

test('strona zatwierdzenia PO: escapuje nazwy z cenników (XSS), brak formularza dla zatwierdzonego', () => {
  const [x] = runCode('po-approve-page', { input: [po({ supplier: '<script>1</script>', lines: [{ name: '<img src=x onerror=1>', unit: 'm2', qty: 1, unit_price: 1 }] })] });
  assert.ok(!x.html.includes('<script>') && !x.html.includes('<img src=x'));
  const [sent] = runCode('po-approve-page', { input: [po({ status: 'sent' })] });
  assert.ok(!sent.html.includes('<form'));
  assert.equal(runCode('po-approve-page', { input: [{}] })[0].code, 404);
});

test('wynik zatwierdzenia PO: link do przyjęcia dostawy albo komunikat błędu', () => {
  const cfg = { publicUrl: 'http://x' };
  const [ok] = runCode('po-approve-result', { nodes: { 'Config POST approve': cfg }, input: [{ ok: true, po_id: ID, supplier: 'Hurt A', total: 361 }] });
  assert.match(ok.html, /http:\/\/x\/webhook\/po-received\?po_id=/);
  const [bad] = runCode('po-approve-result', { nodes: { 'Config POST approve': cfg }, input: [{ ok: false, error: 'PO_NOT_DRAFT' }] });
  assert.equal(bad.code, 409);
  assert.match(bad.html, /już zatwierdzone/);
});

test('strona i wynik przyjęcia dostawy', () => {
  const [page] = runCode('po-receive-page', { input: [po({ status: 'sent' })] });
  assert.match(page.html, /action="\/webhook\/po-received"/);
  assert.ok(!runCode('po-receive-page', { input: [po({ status: 'draft' })] })[0].html.includes('<form'));
  assert.equal(runCode('po-receive-result', { input: [{ ok: true }] })[0].code, 200);
  assert.equal(runCode('po-receive-result', { input: [{ ok: false, error: 'PO_NOT_SENT' }] })[0].code, 409);
});

test('cron-params: harmonogram zawsze, webhook tylko w trybie testowym, adres opinii z webhooka tylko w trybie testowym', () => {
  const run = (i) => runCode('cron-params', { input: [i] })[0];
  assert.deepEqual([run({ allowMock: '0' }).allowed, run({ headers: {}, allowMock: '0' }).allowed, run({ headers: {}, allowMock: '1' }).allowed], [true, false, true]);
  assert.equal(run({ headers: {}, allowMock: '1', body: { review_url: 'https://g.page/r/x' } }).reviewUrl, 'https://g.page/r/x');
  assert.equal(run({ headers: {}, allowMock: '1', body: { review_url: 5 } }).allowed, false);
  assert.equal(run({ headers: {}, allowMock: '0', body: { review_url: 'https://g.page/r/x' } }).allowed, false);
  assert.equal(run({ reviewUrl: '' }).reviewUrl, null, 'pusty adres opinii = null (wyłączone)');
  assert.equal(run({ reviewUrl: 'https://g.page/r/cfg', allowMock: '0' }).reviewUrl, 'https://g.page/r/cfg');
  assert.equal(run({ statusUrl: 'http://localhost:8080' }).statusUrl, 'http://localhost:8080');
});
