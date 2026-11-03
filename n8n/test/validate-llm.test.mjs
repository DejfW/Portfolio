import test from 'node:test';
import assert from 'node:assert/strict';
import { runCode } from './harness.mjs';

const catalog = {
  products: [{ id: 'P-STOL', name: 'Stół dębowy' }, { id: 'P-KOM', name: 'Komoda' }],
  materials: [{ id: 'M-DAB', name: 'Dąb' }],
};

function validate(llmText, cat = catalog) {
  const [r] = runCode('validate-llm', {
    nodes: { Normalize: { external_id: 'x', source: 'form', customer_email: 'a@b.cc', message: 'wiadomość' }, Catalog: cat },
    input: [{ text: llmText }],
  });
  return r;
}
const json = (o) => JSON.stringify(o);

test('poprawne zamówienie z katalogu', () => {
  const r = validate(json({ kind: 'catalog', items: [{ product: 'komoda', qty: 2 }], missing: [] }));
  assert.equal(r.route, 'ok');
  assert.deepEqual(r.payload.items, [{ product_id: 'P-KOM', qty: 2 }]);
  assert.equal(r.payload.kind, 'catalog');
});

test('mebel na wymiar mapuje materiał na id i przekazuje wymiary', () => {
  const r = validate(json({ kind: 'custom', items: [{ custom: { width_cm: 120, height_cm: 90, depth_cm: 45, material: 'DĄB' }, qty: 1 }], missing: [] }));
  assert.equal(r.route, 'ok');
  assert.deepEqual(r.payload.items[0].custom_spec, { width_cm: 120, height_cm: 90, depth_cm: 45, material_id: 'M-DAB' });
});

test('blok ```json i tekst wokół są ignorowane', () => {
  const r = validate('Oto wynik:\n```json\n' + json({ kind: 'catalog', items: [{ product: 'Komoda', qty: 1 }], missing: [] }) + '\n```');
  assert.equal(r.route, 'ok');
});

test('niepoprawny JSON i pusty tekst to needs_review, bez wyjątku', () => {
  for (const t of ['', 'nie json', '{niepoprawny', '[1,2]', 'null']) {
    const r = validate(t);
    assert.equal(r.route, 'needs_review', `tekst: ${t}`);
  }
});

test('obiekt zamiast nazwy produktu nie przewraca walidatora (zarzut 6)', () => {
  for (const product of [{ toString: null }, { a: 1 }, [1], 42, null, true]) {
    const r = validate(json({ kind: 'catalog', items: [{ product, qty: 1 }], missing: [] }));
    assert.equal(r.route, 'needs_review', `product: ${JSON.stringify(product)}`);
  }
  const r = validate(json({ kind: 'custom', items: [{ custom: { width_cm: 50, height_cm: 50, depth_cm: 50, material: { toString: null } }, qty: 1 }], missing: [] }));
  assert.equal(r.route, 'needs_review');
});

test('kolizja nazw po normalizacji kieruje do człowieka (zarzut 9)', () => {
  const colliding = { products: [{ id: 'A', name: 'Stół' }, { id: 'B', name: 'STÓŁ' }], materials: [] };
  const r = validate(json({ kind: 'catalog', items: [{ product: 'Stół', qty: 1 }], missing: [] }), colliding);
  assert.equal(r.route, 'needs_review');
  assert.match(r.reason, /AMBIGUOUS/);
  // ta sama nazwa w NFC i NFD to ten sam produkt, a nie kolizja dwóch różnych
  const nfd = { products: [{ id: 'A', name: 'Stół' }], materials: [] };
  const ok = validate(json({ kind: 'catalog', items: [{ product: 'Stół', qty: 1 }], missing: [] }), nfd);
  assert.equal(ok.route, 'ok');
});

test('niepoprawna lista braków to needs_review, a nie ciche pominięcie (zarzut 10)', () => {
  for (const missing of [[null, 42], [''], 'wymiary', { a: 1 }, [[]]]) {
    const r = validate(json({ kind: 'catalog', items: [{ product: 'Komoda', qty: 1 }], missing }));
    assert.equal(r.route, 'needs_review', `missing: ${JSON.stringify(missing)}`);
  }
});

test('prawdziwe braki to needs_info z listą dla klienta', () => {
  const r = validate(json({ kind: 'custom', items: [], missing: ['wymiary mebla', ' rodzaj materiału '] }));
  assert.equal(r.route, 'needs_info');
  assert.deepEqual(r.missing, ['wymiary mebla', 'rodzaj materiału']);
});

test('brak ilości to pytanie do klienta, a nie domyślna jedynka (zarzut 10)', () => {
  const r = validate(json({ kind: 'catalog', items: [{ product: 'Komoda' }, { product: 'Stół dębowy', qty: 1 }], missing: [] }));
  assert.equal(r.route, 'needs_info');
  assert.match(r.missing[0], /Komoda/);
});

test('nieprawidłowa ilość to needs_review', () => {
  for (const qty of [0, -1, 1.5, '2', null, 1001]) {
    const r = validate(json({ kind: 'catalog', items: [{ product: 'Komoda', qty }], missing: [] }));
    assert.equal(r.route, 'needs_review', `qty: ${JSON.stringify(qty)}`);
  }
});

test('nieznany produkt, pusta lista pozycji i zły kind to needs_review', () => {
  assert.equal(validate(json({ kind: 'catalog', items: [{ product: 'Fotel', qty: 1 }], missing: [] })).route, 'needs_review');
  assert.equal(validate(json({ kind: 'catalog', items: [], missing: [] })).route, 'needs_review');
  assert.equal(validate(json({ kind: 'inne', items: [{ product: 'Komoda', qty: 1 }], missing: [] })).route, 'needs_review');
});

test('ładunek dla bazy nie zawiera danych klienta spoza zamówienia', () => {
  const r = validate(json({ kind: 'catalog', items: [{ product: 'Komoda', qty: 1 }], missing: [] }));
  assert.deepEqual(Object.keys(r.payload).sort(), ['items', 'kind', 'parsed', 'route']);
});
