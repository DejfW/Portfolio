import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseSlug, loadProject, loadProjects } from '../js/lib/load.js';

const proj = (slug, over = {}) => ({ slug, title: slug, status: 'planned', tagline: 't', ...over });

const fakeFetch = (map) => async (url) => {
  if (!(url in map)) throw new Error(`404 ${url}`);
  return map[url];
};

test('parseSlug accepts valid and rejects traversal', () => {
  assert.equal(parseSlug('?p=meble-automatyzacja'), 'meble-automatyzacja');
  for (const bad of ['?p=../../etc/passwd', '?p=A_B', '?p=a//b', '', '?x=1', '?p=', '?p=a%2f..%2fb']) {
    assert.equal(parseSlug(bad), null, bad);
  }
});

test('loadProjects returns projects in manifest order', async () => {
  const f = fakeFetch({
    'projects/index.json': { projects: ['b', 'a'] },
    'projects/a/project.json': proj('a'),
    'projects/b/project.json': proj('b'),
  });
  const { projects, errors } = await loadProjects(f);
  assert.deepEqual(projects.map((p) => p.slug), ['b', 'a']);
  assert.deepEqual(errors, []);
});

test('loadProjects skips broken project and reports it', async () => {
  const f = fakeFetch({
    'projects/index.json': { projects: ['a', 'bad', 'c'] },
    'projects/a/project.json': proj('a'),
    'projects/bad/project.json': { slug: 'bad', title: 'x' },
    'projects/c/project.json': proj('c'),
  });
  const { projects, errors } = await loadProjects(f);
  assert.deepEqual(projects.map((p) => p.slug), ['a', 'c']);
  assert.equal(errors.length, 1);
  assert.match(errors[0], /bad/);
});

test('loadProjects skips project whose fetch throws', async () => {
  const f = fakeFetch({
    'projects/index.json': { projects: ['a', 'gone'] },
    'projects/a/project.json': proj('a'),
  });
  const { projects, errors } = await loadProjects(f);
  assert.equal(projects.length, 1);
  assert.match(errors[0], /gone/);
});

test('loadProjects with missing manifest returns empty and an error', async () => {
  const { projects, errors } = await loadProjects(fakeFetch({}));
  assert.deepEqual(projects, []);
  assert.equal(errors.length, 1);
});

test('loadProjects with invalid manifest returns empty and an error', async () => {
  const { projects, errors } = await loadProjects(fakeFetch({ 'projects/index.json': { projects: ['../x'] } }));
  assert.deepEqual(projects, []);
  assert.ok(errors.length >= 1);
});

test('loadProject returns null project for unknown slug without throwing', async () => {
  const r = await loadProject(fakeFetch({}), 'nope');
  assert.equal(r.project, null);
  assert.equal(r.errors.length, 1);
});

test('loadProject rejects an unsafe slug without fetching', async () => {
  let called = false;
  const r = await loadProject(async () => { called = true; return {}; }, '../../etc/passwd');
  assert.equal(r.project, null);
  assert.equal(called, false);
});
