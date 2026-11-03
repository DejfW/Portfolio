import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { mkdtempSync, writeFileSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createPortfolioServer } from '../../scripts/serve-portfolio.mjs';

let server, port, outside;

before(async () => {
  const base = mkdtempSync(join(tmpdir(), 'pfs-'));
  const root = join(base, 'root');
  mkdirSync(root);
  writeFileSync(join(base, 'README.md'), 'outside');
  writeFileSync(join(root, 'index.html'), '<h1>hi</h1>');
  writeFileSync(join(root, 'a.txt'), 'plain');
  writeFileSync(join(root, '.secret'), 'nope');
  writeFileSync(join(root, 'v.mp4'), Buffer.alloc(1000, 1));
  outside = base;
  server = createPortfolioServer(root);
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  port = server.address().port;
});
after(() => server.close());

const req = (path, { method = 'GET', headers = {} } = {}) => new Promise((resolve, reject) => {
  const r = http.request({ host: '127.0.0.1', port, path, method, headers }, (res) => {
    const chunks = [];
    res.on('data', (c) => chunks.push(c));
    res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks) }));
  });
  r.on('error', reject);
  r.end();
});

test('serves index.html at /', async () => {
  const r = await req('/');
  assert.equal(r.status, 200);
  assert.match(r.headers['content-type'], /^text\/html/);
  assert.equal(r.body.toString(), '<h1>hi</h1>');
});

test('blocks path traversal', async () => {
  for (const p of ['/..%2f..%2fREADME.md', '/%2e%2e/README.md', '/%00', '/..%5cREADME.md']) {
    const r = await req(p);
    assert.ok([400, 404].includes(r.status), `${p} -> ${r.status}`);
    assert.notEqual(r.body.toString(), 'outside');
  }
});

test('404 for dotfiles', async () => {
  assert.equal((await req('/.secret')).status, 404);
});

test('range request returns 206 with Content-Range', async () => {
  const r = await req('/v.mp4', { headers: { Range: 'bytes=0-99' } });
  assert.equal(r.status, 206);
  assert.equal(r.headers['content-range'], 'bytes 0-99/1000');
  assert.equal(r.headers['accept-ranges'], 'bytes');
  assert.equal(r.body.length, 100);
});

test('open-ended range returns the tail', async () => {
  const r = await req('/v.mp4', { headers: { Range: 'bytes=900-' } });
  assert.equal(r.status, 206);
  assert.equal(r.headers['content-range'], 'bytes 900-999/1000');
});

test('unsatisfiable range returns 416', async () => {
  const r = await req('/v.mp4', { headers: { Range: 'bytes=5000-' } });
  assert.equal(r.status, 416);
});

test('rejects POST with 405', async () => {
  assert.equal((await req('/', { method: 'POST' })).status, 405);
});

test('sets nosniff and CSP', async () => {
  const r = await req('/a.txt');
  assert.equal(r.headers['x-content-type-options'], 'nosniff');
  const csp = r.headers['content-security-policy'];
  for (const part of ["default-src 'self'", 'font-src https://fonts.gstatic.com', "style-src 'self' https://fonts.googleapis.com", "media-src 'self'"]) {
    assert.ok(csp.includes(part), `${part} missing in ${csp}`);
  }
});

test('unknown path returns 404', async () => {
  assert.equal((await req('/nope.html')).status, 404);
});
