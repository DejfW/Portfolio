import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  isSafeRelPath, isSafeUrl, validateProject, validateManifest, validateSite, safeLinks,
} from '../js/lib/schema.js';

const ctx = (over = {}) => ({ slug: 'demo', fileExists: () => true, ...over });

const planned = () => ({ slug: 'demo', title: 'Demo', status: 'planned', tagline: 'A demo project' });

const shipped = (sections) => ({
  slug: 'demo', title: 'Demo', status: 'shipped', tagline: 'A demo project', summary: 'Summary.',
  year: 2026, role: 'Author', tags: ['n8n'], cover: 'media/cover.png',
  links: [{ label: 'Repo', url: 'https://github.com/DejfW/Portfolio' }],
  stats: [{ value: '14', label: 'workflows' }],
  sections: sections || [{ type: 'prose', paragraphs: ['Hello'] }],
});

const allBlocks = () => [
  { type: 'prose', title: 'P', paragraphs: ['a', 'b'] },
  { type: 'list', items: [{ title: 't', text: 'x' }] },
  { type: 'table', columns: ['A', 'B'], rows: [['1', '2']] },
  { type: 'gallery', items: [
    { type: 'image', src: 'media/a.png', alt: 'An image' },
    { type: 'video', src: 'media/v.mp4', poster: 'media/p.png' },
  ] },
  { type: 'diagram', src: 'media/d.svg', alt: 'Diagram' },
  { type: 'chart', unit: 'files', bars: [{ label: 'a', value: 3 }, { label: 'b', value: 0 }] },
  { type: 'graph', nodes: [
    { id: 'a', label: 'A', layer: 0, kind: 'channel' }, { id: 'b', label: 'B', layer: 1 },
  ], edges: [{ from: 'a', to: 'b' }] },
];

test('valid planned project passes', () => {
  assert.deepEqual(validateProject(planned(), ctx()), []);
});

test('valid shipped project with every block type passes', () => {
  assert.deepEqual(validateProject(shipped(allBlocks()), ctx()), []);
});

test('slug must equal folder name', () => {
  const errs = validateProject({ ...planned(), slug: 'other' }, ctx());
  assert.ok(errs.some((e) => e.startsWith('slug:')), errs.join('\n'));
});

test('planned project does not need sections', () => {
  assert.deepEqual(validateProject(planned(), ctx()), []);
});

test('shipped without sections is rejected', () => {
  const p = shipped(); delete p.sections;
  const errs = validateProject(p, ctx());
  assert.ok(errs.some((e) => e.startsWith('sections:')), errs.join('\n'));
});

test('rejects javascript: link url', () => {
  const p = shipped(); p.links = [{ label: 'x', url: 'javascript:alert(1)' }];
  const errs = validateProject(p, ctx());
  assert.ok(errs.some((e) => e.startsWith('links[0].url:')), errs.join('\n'));
  assert.equal(isSafeUrl('https://github.com/x'), true);
  assert.equal(isSafeUrl('data:text/html,x'), false);
  assert.equal(isSafeUrl('mailto:a@example.com'), false);
  assert.equal(isSafeUrl('mailto:a@example.com', { allowMailto: true }), true);
});

test('rejects media path escape', () => {
  for (const bad of ['../../.env', '/etc/passwd', 'https://obcy/x.png', 'a\\b.png', 'media/x.exe', 'media/../../a.png']) {
    assert.equal(isSafeRelPath(bad), false, bad);
  }
  assert.equal(isSafeRelPath('media/a.png'), true);
  const errs = validateProject(shipped([{ type: 'gallery', items: [{ type: 'image', src: '../../.env', alt: 'x' }] }]), ctx());
  assert.ok(errs.some((e) => e.startsWith('sections[0].items[0].src:')), errs.join('\n'));
});

test('rejects missing media file', () => {
  const none = ctx({ fileExists: () => false });
  const errs = validateProject(shipped(allBlocks()), none);
  assert.ok(errs.length > 0);
  assert.ok(errs.every((e) => e.endsWith('file not found')), errs.join('\n'));
  for (const field of ['cover:', 'sections[3].items[1].poster:', 'sections[4].src:']) {
    assert.ok(errs.some((e) => e.startsWith(field)), field + '\n' + errs.join('\n'));
  }
});

test('image requires alt', () => {
  const errs = validateProject(shipped([{ type: 'gallery', items: [{ type: 'image', src: 'media/a.png' }] }]), ctx());
  assert.ok(errs.some((e) => e.includes('alt')), errs.join('\n'));
});

test('video does not require alt', () => {
  const errs = validateProject(shipped([{ type: 'gallery', items: [{ type: 'video', src: 'media/v.mp4' }] }]), ctx());
  assert.deepEqual(errs, []);
});

test('empty gallery is allowed', () => {
  assert.deepEqual(validateProject(shipped([{ type: 'gallery', items: [] }]), ctx()), []);
});

test('table row length must match columns', () => {
  const errs = validateProject(shipped([{ type: 'table', columns: ['A', 'B'], rows: [['1']] }]), ctx());
  assert.ok(errs.some((e) => e.startsWith('sections[0].rows[0]:')), errs.join('\n'));
});

test('graph edge must reference known nodes and go to a later layer', () => {
  const nodes = [{ id: 'a', label: 'A', layer: 0 }, { id: 'b', label: 'B', layer: 1 }];
  const run = (edges) => validateProject(shipped([{ type: 'graph', nodes, edges }]), ctx());
  assert.ok(run([{ from: 'a', to: 'zzz' }]).some((e) => e.includes('zzz')));
  assert.ok(run([{ from: 'b', to: 'a' }]).some((e) => e.includes('later layer')));
  assert.ok(run([{ from: 'a', to: 'a' }]).some((e) => e.includes('later layer')));
  assert.deepEqual(run([{ from: 'a', to: 'b' }]), []);
});

test('chart rejects negative and non-finite values', () => {
  for (const v of [-1, Infinity, NaN, '3']) {
    const errs = validateProject(shipped([{ type: 'chart', bars: [{ label: 'a', value: v }] }]), ctx());
    assert.ok(errs.some((e) => e.startsWith('sections[0].bars[0].value:')), String(v));
  }
});

test('unknown block type names the type', () => {
  const errs = validateProject(shipped([{ type: 'sparkles' }]), ctx());
  assert.ok(errs.some((e) => e.includes('sparkles')), errs.join('\n'));
});

test('manifest rejects duplicate and invalid slugs', () => {
  assert.ok(validateManifest({ projects: ['a', 'a'] }).some((e) => e.includes('duplicate')));
  assert.ok(validateManifest({ projects: ['../x'] }).length > 0);
  assert.ok(validateManifest({ projects: ['Bad_Slug'] }).length > 0);
  assert.ok(validateManifest({}).length > 0);
});

test('manifest accepts valid', () => {
  assert.deepEqual(validateManifest({ projects: ['meble-automatyzacja', 'x1'] }), []);
});

const site = (over = {}) => ({
  name: 'Dawid', headline: 'Hi',
  about: { title: 'About me', paragraphs: ['x'] },
  links: [{ label: 'GitHub', url: 'https://github.com/DejfW' }], ...over,
});
const sctx = (over = {}) => ({ fileExists: () => true, ...over });

test('site accepts minimal valid site and optional cv absent', () => {
  assert.deepEqual(validateSite(site(), sctx()), []);
});

test('site rejects cv that is not a .pdf or is missing on disk', () => {
  const notPdf = validateSite(site({ cv: { label: 'CV', url: 'assets/cv.docx' } }), sctx());
  assert.ok(notPdf.some((e) => e.startsWith('cv.url:')));
  const missing = validateSite(site({ cv: { label: 'CV', url: 'assets/cv.pdf' } }), sctx({ fileExists: () => false }));
  assert.ok(missing.some((e) => e.startsWith('cv.url:') && e.endsWith('file not found')));
  assert.deepEqual(validateSite(site({ cv: { label: 'CV', url: 'assets/cv.pdf' } }), sctx()), []);
});

test('site rejects javascript: link', () => {
  const errs = validateSite(site({ links: [{ label: 'x', url: 'javascript:alert(1)' }] }), sctx());
  assert.ok(errs.some((e) => e.startsWith('links[0].url:')));
});

test('site allows mailto: only in links', () => {
  assert.deepEqual(validateSite(site({ links: [{ label: 'Mail', url: 'mailto:a@example.com' }] }), sctx()), []);
  const errs = validateSite(site({ cv: { label: 'CV', url: 'mailto:a@example.com' } }), sctx());
  assert.ok(errs.some((e) => e.startsWith('cv.url:')));
});

test('safeLinks drops unsafe and malformed links', () => {
  const out = safeLinks([
    { label: 'ok', url: 'https://github.com/DejfW' },
    { label: 'mail', url: 'mailto:a@example.com' },
    { label: 'bad', url: 'javascript:alert(1)' },
    null, { label: 5, url: 'https://x.y' }, { label: 'nourl' },
  ]);
  assert.deepEqual(out.map((l) => l.label), ['ok', 'mail']);
  assert.deepEqual(safeLinks(undefined), []);
});

test('validateSite never throws on malformed shapes', () => {
  for (const bad of [{ links: [null] }, { skills: [{ group: 'g', items: 'x' }] }, { highlights: [null] }, { about: null }, { cv: null }]) {
    assert.doesNotThrow(() => validateSite({ name: 'a', headline: 'b', ...bad }, sctx()));
    assert.ok(validateSite({ name: 'a', headline: 'b', ...bad }, sctx()).length > 0, JSON.stringify(bad));
  }
});
