import test from 'node:test';
import assert from 'node:assert/strict';
import { runCode } from './harness.mjs';

const valid = { customer_email: 'anna@example.com', message: 'Szafka', external_id: 'abc-1', source: 'email' };
const norm = (body, extra = {}) =>
  runCode('normalize', { input: [{ authorized: true, allowMock: '0', headers: {}, body, ...extra }] })[0];

test('poprawne żądanie przechodzi', () => {
  const r = norm(valid);
  assert.equal(r.valid, true);
  assert.equal(r.source, 'email');
});

test('external_id jest wymagany i ma ograniczony zestaw znaków (zarzut 8)', () => {
  for (const external_id of [undefined, null, '', 42, 'ze spacją', 'a'.repeat(201), "x'; drop"]) {
    const r = norm({ ...valid, external_id });
    assert.equal(r.valid, false, `external_id: ${JSON.stringify(external_id)}`);
    assert.ok(r.errors.includes('external_id'));
  }
});

test('zły e-mail, pusta lub zbyt długa wiadomość i zły source są odrzucane', () => {
  assert.ok(norm({ ...valid, customer_email: 'bez-malpy' }).errors.includes('customer_email'));
  assert.ok(norm({ ...valid, customer_email: 'a b@c.pl' }).errors.includes('customer_email'));
  assert.ok(norm({ ...valid, message: '   ' }).errors.includes('message'));
  assert.ok(norm({ ...valid, message: 'x'.repeat(5001) }).errors.includes('message'));
  assert.ok(norm({ ...valid, source: 'sms' }).errors.includes('source'));
  assert.equal(norm(null).valid, false);
});

test('brak autoryzacji blokuje żądanie (zarzut 3)', () => {
  const r = norm(valid, { authorized: false });
  assert.equal(r.valid, false);
  assert.ok(r.errors.includes('unauthorized'));
});

test('nagłówek X-LLM-Mock działa tylko w trybie testowym i dla poprawnych nazw (zarzut 4)', () => {
  assert.equal(norm(valid, { allowMock: '1', headers: { 'x-llm-mock': 'catalog' } }).mock, 'catalog');
  assert.ok(norm(valid, { allowMock: '0', headers: { 'x-llm-mock': 'catalog' } }).errors.includes('x-llm-mock'));
  assert.ok(norm(valid, { allowMock: '1', headers: { 'x-llm-mock': '../../etc/passwd' } }).errors.includes('x-llm-mock'));
  assert.ok(norm(valid, { allowMock: '1', headers: { 'x-llm-mock': 'Catalog' } }).errors.includes('x-llm-mock'));
});

const cfg = { ownerEmail: 'owner@example.com', publicUrl: 'http://x' };
const compose = (contexts) => runCode('compose-emails', { nodes: { Config: cfg }, input: contexts });
const base = { order_id: 'o-1', customer_email: 'k@example.com', source: 'form', raw_text: 'Chcę szafkę', existing_kinds: [] };

test('quoted daje maila do klienta z kwotą i alert z linkiem zatwierdzenia', () => {
  const m = compose([{ ...base, status: 'quoted', quote: { total: 1266.5, lines: [{ label: 'Szafka', qty: 2 }] } }]);
  assert.deepEqual(m.map((x) => x.kind).sort(), ['customer_quote', 'owner_alert']);
  assert.match(m.find((x) => x.kind === 'customer_quote').body, /1266,50 zł/);
  assert.match(m.find((x) => x.kind === 'owner_alert').body, /\/webhook\/approve\?order_id=o-1/);
  assert.equal(m.find((x) => x.kind === 'owner_alert').to, 'owner@example.com');
});

test('istniejące maile są pomijane, więc naprawa uzupełnia tylko brakujące (zarzut 2)', () => {
  const m = compose([{ ...base, status: 'quoted', quote: { total: 10, lines: [] }, existing_kinds: ['customer_quote'] }]);
  assert.deepEqual(m.map((x) => x.kind), ['owner_alert']);
  assert.deepEqual(compose([{ ...base, status: 'quoted', quote: { total: 10, lines: [] }, existing_kinds: ['customer_quote', 'owner_alert'] }]), []);
});

test('needs_info i needs_review dają po jednym mailu właściwego rodzaju', () => {
  const info = compose([{ ...base, status: 'needs_info', missing: ['wymiary'] }]);
  assert.deepEqual(info.map((x) => x.kind), ['needs_info']);
  assert.match(info[0].body, /- wymiary/);
  const rev = compose([{ ...base, status: 'needs_review', reason: 'STUCK_INTAKE' }]);
  assert.deepEqual(rev.map((x) => x.kind), ['owner_alert']);
  assert.match(rev[0].body, /STUCK_INTAKE/);
});

test('brak zamówienia, quoted bez wyceny i wiele zamówień naraz nie przewracają kodu', () => {
  assert.deepEqual(compose([{ ...base, order_id: undefined }]), []);
  assert.deepEqual(compose([{ ...base, status: 'quoted', quote: null }]), []);
  assert.equal(compose([{ ...base, status: 'needs_info', order_id: 'a' }, { ...base, status: 'needs_info', order_id: 'b' }]).length, 2);
});
