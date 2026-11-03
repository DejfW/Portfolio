import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { runCode } from './harness.mjs';

const messy = readFileSync(new URL('../../data/suppliers-test/mieszany.csv', import.meta.url), 'utf8');

test('csv-parse: BOM, CRLF, cudzysłowy z przecinkami, komentarze i puste linie', () => {
  const [r] = runCode('csv-parse', { input: [{ stdout: messy }] });
  assert.deepEqual(r.rows[0], { supplier: 'Hurtownia Drewna Lasek', material: 'Płyta dębowa 18 mm', price: '201,50' });
  assert.ok(r.rows.some((x) => x.material === 'Materiał, z przecinkiem' && x.price === '10.00'), 'przecinek w cudzysłowie');
  assert.ok(!r.rows.some((x) => x.supplier === 'supplier'), 'nagłówek pominięty');
  assert.ok(!r.rows.some((x) => String(x.supplier).startsWith('#')), 'komentarz pominięty');
  assert.equal(r.rows.length, 9);
});

test('csv-parse: wiersze uszkodzone przechodzą jako {raw} bez ceny, a nie jako częściowo poprawne (zarzut 11)', () => {
  const run = (stdout) => runCode('csv-parse', { input: [{ stdout }] })[0].rows;
  assert.deepEqual(run('H,M,"1\n'), [{ raw: 'H,M,"1' }]);            // niedomknięty cudzysłów
  assert.deepEqual(run('H,M,2,99\n'), [{ raw: 'H,M,2,99' }]);        // czwarta kolumna
  assert.deepEqual(run('Okucia24 Hurt,tylko dwie kolumny\n'), [{ raw: 'Okucia24 Hurt,tylko dwie kolumny' }]);
  assert.deepEqual(run('H,M,2\n'), [{ supplier: 'H', material: 'M', price: '2' }]);
  assert.equal(run('x'.repeat(500) + ',a\n')[0].raw.length, 200);       // długie surowe wiersze są skracane
});

test('csv-parse: kilka plików po sobie i brak danych', () => {
  const two = 'supplier,material,price\nA,X,1\nsupplier,material,price\nB,Y,2\n';
  assert.equal(runCode('csv-parse', { input: [{ stdout: two }] })[0].rows.length, 2);
  for (const stdout of [undefined, '', '\n\n']) assert.deepEqual(runCode('csv-parse', { input: [{ stdout }] })[0].rows, []);
});

test('csv-parse: cudzysłów w cudzysłowie i nieprzewidziane znaki nie psują wierszy', () => {
  const [r] = runCode('csv-parse', { input: [{ stdout: 'H,"Płyta ""premium"", 18 mm",5.5\n' }] });
  assert.equal(r.rows[0].material, 'Płyta "premium", 18 mm');
});

const params = { today: '2026-11-03', key: '2026-11-03' };
const digest = (imp, rep) => runCode('stock-digest', { nodes: { 'Stock params': params, 'Import prices': imp }, input: [rep] })[0];

test('digest: materiały do zamówienia, problemy importu i brak ceny', () => {
  const d = digest(
    { updated: 12, unknown_suppliers: ['Nie ma'], unknown_materials: ['Cos <b>'], invalid: [{}, {}] },
    { items: [{ name: 'Olej do drewna', available: 2, to_order: 4, best_supplier: 'Okucia24 Hurt', best_price: 79 },
              { name: 'Lakier', available: 0, to_order: 10, best_supplier: null, best_price: null }], unpriced: ['Lakier'] });
  const n = d.p[0];
  assert.deepEqual([n.channel, n.kind, n.dedupe_key], ['slack', 'stock_digest', 'stock-digest:2026-11-03']);
  assert.match(n.text, /zaktualizowane: 12/);
  assert.match(n.text, /Nieznane hurtownie: Nie ma/);
  assert.match(n.text, /Cos &lt;b&gt;/);
  assert.match(n.text, /Błędnych wierszy: 2/);
  assert.match(n.text, /Olej do drewna: dostępne 2, do zamówienia 4, najtaniej: Okucia24 Hurt po 79,00 zł/);
  assert.match(n.text, /Lakier: dostępne 0.*brak aktualnej ceny/);
  assert.match(n.text, /Bez aktualnej ceny w hurtowniach: Lakier/);
});

test('digest: cisza, gdy wszystko w porządku, a brak importu to ostrzeżenie', () => {
  assert.deepEqual(digest({ updated: 5, unknown_suppliers: [], unknown_materials: [], invalid: [] }, { items: [], unpriced: [] }).p, []);
  const none = digest({ updated: 0, unknown_suppliers: [], unknown_materials: [], invalid: [] }, { items: [], unpriced: [] });
  assert.match(none.p[0].text, /Żadna cena nie została zaktualizowana/);
  const err = digest({ error: 'INVALID_ROWS' }, { items: [], unpriced: [] });
  assert.match(err.p[0].text, /Import cenników nie powiódł się \(INVALID_ROWS\)/);
});

test('stock-params: tryb produkcyjny nie przyjmuje niczego z zewnątrz', () => {
  const run = (i) => runCode('stock-params', { input: [{ projectDir: '/proj', ...i }] })[0];
  assert.deepEqual([run({}).allowed, run({}).dir], [true, 'suppliers']);                       // harmonogram
  assert.equal(run({ headers: {}, allowMock: '0', body: { dir: 'suppliers-test' } }).allowed, false); // webhook bez trybu testowego
  const t = run({ headers: {}, allowMock: '1', body: { dir: 'suppliers-test', digest_key: 'k-1' } });
  assert.deepEqual([t.allowed, t.dir, t.key], [true, 'suppliers-test', 'k-1']);
  for (const dir of ['../etc', 'a/b', 'A', '', 5]) assert.equal(run({ headers: {}, allowMock: '1', body: { dir } }).allowed, false, `dir: ${dir}`);
  assert.equal(run({ headers: {}, allowMock: '1', body: { digest_key: 'x y' } }).allowed, false);
  assert.throws(() => run({ projectDir: '/a"; rm -rf /' }), /INVALID_PROJECT_DIR/);
});
