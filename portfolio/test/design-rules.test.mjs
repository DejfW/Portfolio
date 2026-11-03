// Wymusza "Don'ts" z portfolio/DESIGN.md na plikach CSS.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const cssDir = join(dirname(fileURLToPath(import.meta.url)), '..', 'css');
const read = (n) => (existsSync(join(cssDir, n)) ? readFileSync(join(cssDir, n), 'utf8').replace(/\/\*[\s\S]*?\*\//g, '') : '');
const tokens = read('tokens.css');
const styled = { 'base.css': read('base.css'), 'components.css': read('components.css') };

// Rozbija CSS na pary { selector, body } (bez zagnieżdżeń poza @media, które spłaszczamy).
function rules(css) {
  const out = [];
  const re = /([^{}]+)\{([^{}]*)\}/g;
  let m;
  while ((m = re.exec(css))) out.push({ selector: m[1].trim(), body: m[2] });
  return out;
}

test('tokens.css exists and defines the palette', () => {
  for (const t of ['--color-void-base: #0e0918', '--gradient-ember-cta', '--gradient-electric-current', '--shadow-sm']) {
    assert.ok(tokens.includes(t), `${t} missing`);
  }
});

test('no hex or rgb literals outside tokens.css', () => {
  for (const [name, css] of Object.entries(styled)) {
    assert.doesNotMatch(css, /#[0-9a-fA-F]{3,8}\b/, `${name} has a hex literal`);
    assert.doesNotMatch(css, /\b(rgb|rgba|hsl|hsla)\(/, `${name} has a color function`);
  }
});

test('font-weight is 300 or 400 only', () => {
  const ok = new Set(['300', '400', 'var(--font-weight-light)', 'var(--font-weight-regular)']);
  for (const [name, css] of Object.entries({ 'tokens.css': tokens, ...styled })) {
    for (const m of css.matchAll(/font-weight\s*:\s*([^;}]+)/g)) {
      assert.ok(ok.has(m[1].trim()), `${name}: font-weight ${m[1].trim()}`);
    }
  }
});

test('ember gradient only on .btn-primary', () => {
  for (const [name, css] of Object.entries(styled)) {
    for (const r of rules(css)) {
      if (r.body.includes('--gradient-ember-cta')) {
        assert.ok(r.selector.split(',').every((s) => /\.btn-primary\b/.test(s)), `${name}: ${r.selector}`);
      }
    }
  }
});

test('no outset box-shadows', () => {
  const ok = new Set(['none', 'var(--shadow-subtle-2)', 'var(--shadow-subtle)', 'var(--shadow-sm)']);
  for (const [name, css] of Object.entries(styled)) {
    for (const r of rules(css)) {
      for (const m of r.body.matchAll(/box-shadow\s*:\s*([^;]+)/g)) {
        const v = m[1].trim();
        assert.ok(ok.has(v), `${name}: ${r.selector} box-shadow ${v}`);
        if (v === 'var(--shadow-sm)') assert.match(r.selector, /\.btn-frosted\b/, `${name}: --shadow-sm outside .btn-frosted`);
      }
    }
  }
});

test('no body text in pure white', () => {
  for (const [name, css] of Object.entries(styled)) {
    for (const r of rules(css)) {
      if (/^(body|\.t-body)$/.test(r.selector)) {
        assert.doesNotMatch(r.body, /color\s*:\s*var\(--color-cloud-white\)/, `${name}: ${r.selector}`);
      }
    }
  }
});

test('border-radius 9999px only on pills, badges and icon wrappers', () => {
  for (const [name, css] of Object.entries(styled)) {
    for (const r of rules(css)) {
      if (/border-radius\s*:\s*(9999px|var\(--radius-full\)|var\(--radius-pills\))/.test(r.body)) {
        assert.match(r.selector, /\.(pill|badge|tag|dot)\b/, `${name}: ${r.selector}`);
      }
    }
  }
});
