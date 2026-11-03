import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const cli = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'scripts', 'validate-portfolio.mjs');

const project = (over = {}) => ({
  slug: 'demo', title: 'Demo', status: 'shipped', tagline: 't', summary: 's',
  sections: [{ type: 'prose', paragraphs: ['x'] }], ...over,
});
const site = { name: 'D', headline: 'h', links: [{ label: 'GitHub', url: 'https://github.com/DejfW' }] };

// Buduje <tmp>/portfolio/{site.json, projects/...}; zwraca ścieżkę do projects/.
function tree({ manifest = ['demo'], projects = { demo: project() }, extraDirs = [] } = {}) {
  const root = mkdtempSync(join(tmpdir(), 'pf-'));
  const projectsDir = join(root, 'projects');
  mkdirSync(projectsDir, { recursive: true });
  writeFileSync(join(root, 'site.json'), JSON.stringify(site));
  writeFileSync(join(projectsDir, 'index.json'), JSON.stringify({ projects: manifest }));
  for (const [slug, data] of Object.entries(projects)) {
    mkdirSync(join(projectsDir, slug), { recursive: true });
    writeFileSync(join(projectsDir, slug, 'project.json'), JSON.stringify(data));
  }
  for (const d of extraDirs) mkdirSync(join(projectsDir, d), { recursive: true });
  return projectsDir;
}
const run = (dir) => spawnSync(process.execPath, [cli, '--root', dir], { encoding: 'utf8' });

test('cli exits 0 on valid tree', () => {
  const r = run(tree());
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /OK/);
});

test('cli exits 1 on invalid project', () => {
  const r = run(tree({ projects: { demo: project({ links: [{ label: 'x', url: 'javascript:alert(1)' }] }) } }));
  assert.equal(r.status, 1);
  assert.match(r.stderr, /links\[0\]\.url/);
});

test('cli exits 1 when manifest lists missing folder', () => {
  const r = run(tree({ manifest: ['demo', 'ghost'] }));
  assert.equal(r.status, 1);
  assert.match(r.stderr, /ghost/);
});

test('cli warns about folder not in manifest', () => {
  const r = run(tree({ extraDirs: ['stray', '_template'] }));
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /WARN.*stray/);
  assert.doesNotMatch(r.stdout, /_template/);
});

test('cli warns about empty gallery', () => {
  const r = run(tree({ projects: { demo: project({ sections: [{ type: 'gallery', items: [] }] }) } }));
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /WARN.*gallery/);
});

test('cli exits 1 when site.json is invalid', () => {
  const dir = tree();
  writeFileSync(join(dir, '..', 'site.json'), JSON.stringify({ ...site, cv: { label: 'CV', url: 'assets/cv.pdf' } }));
  const r = run(dir);
  assert.equal(r.status, 1);
  assert.match(r.stderr, /cv\.url/);
});
