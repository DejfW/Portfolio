// Ostrzega (nie failuje) o niedokończonych miejscach do uzupełnienia przez autora.
import { test } from 'node:test';
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const walk = (d) => readdirSync(d).flatMap((n) => {
  const p = join(d, n);
  if (n === 'test' || n === '_template') return [];
  return statSync(p).isDirectory() ? walk(p) : /\.(json|html|js|md)$/.test(n) ? [p] : [];
});

test('reports TODO(author) placeholders', (t) => {
  const hits = walk(root).filter((f) => readFileSync(f, 'utf8').includes('TODO(author)'));
  if (hits.length) t.diagnostic(`TODO(author) still present in: ${hits.map((f) => f.slice(root.length + 1)).join(', ')}`);
});
