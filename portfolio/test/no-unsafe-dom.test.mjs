import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');

function walk(dir, exts) {
  return readdirSync(dir).flatMap((n) => {
    const p = join(dir, n);
    if (n === 'test' || n === 'projects' || n === 'node_modules') return [];
    if (statSync(p).isDirectory()) return walk(p, exts);
    return exts.some((e) => n.endsWith(e)) ? [p] : [];
  });
}

test('no innerHTML, outerHTML, insertAdjacentHTML, document.write, eval', () => {
  const files = [...walk(join(root, 'js'), ['.js']), ...walk(root, ['.html']).filter((f) => !f.includes('/js/'))];
  assert.ok(files.length > 0);
  const banned = /\b(innerHTML|outerHTML|insertAdjacentHTML|document\.write|eval|new Function)\b/;
  for (const f of files) assert.doesNotMatch(readFileSync(f, 'utf8'), banned, f);
});

test('no inline scripts or inline style attributes in html (CSP safe)', () => {
  for (const f of walk(root, ['.html'])) {
    const html = readFileSync(f, 'utf8');
    assert.doesNotMatch(html, /<script(?![^>]*\bsrc=)[^>]*>/i, `${f}: inline script`);
    assert.doesNotMatch(html, /\sstyle\s*=/i, `${f}: inline style`);
    assert.doesNotMatch(html, /\son[a-z]+\s*=/i, `${f}: inline handler`);
  }
});

test('every html page carries a CSP meta mirroring the server policy', () => {
  for (const f of walk(root, ['.html'])) {
    const html = readFileSync(f, 'utf8');
    const m = html.match(/<meta http-equiv="Content-Security-Policy" content="([^"]+)"/);
    assert.ok(m, `${f}: missing CSP meta`);
    for (const part of ["default-src 'self'", "script-src 'self'", "base-uri 'none'"]) assert.ok(m[1].includes(part), `${f}: ${part}`);
  }
});
