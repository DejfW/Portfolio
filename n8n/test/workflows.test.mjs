// Testy statyczne wygenerowanych workflow (n8n/workflows/*.json): bezpieczeństwo konfiguracji.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';

const dir = new URL('../workflows/', import.meta.url);
const files = readdirSync(dir).filter((f) => f.endsWith('.json'));
const wf = Object.fromEntries(files.map((f) => [f, JSON.parse(readFileSync(new URL(f, dir), 'utf8'))]));

test('żaden workflow nie zawiera sekretów ani adresu webhooka Slacka', () => {
  for (const [f, w] of Object.entries(wf)) {
    const text = JSON.stringify(w);
    assert.ok(!/hooks\.slack\.com\/services/.test(text), `${f}: adres webhooka`);
    assert.ok(!/eyJ[A-Za-z0-9_-]{20,}/.test(text), `${f}: token JWT`);
  }
});

test('błędne wykonania nie zapisują danych (żądania HTTP zawierają nagłówki z kluczem)', () => {
  for (const [f, w] of Object.entries(wf)) {
    assert.equal(w.settings.saveDataErrorExecution, 'none', `${f}: saveDataErrorExecution`);
  }
});

test('webhooki zmieniające stan (zatwierdzanie i zamykanie zadań) wymagają uwierzytelnienia Basic', () => {
  const team = wf['03-team-tasks.json'];
  const hooks = team.nodes.filter((n) => n.type === 'n8n-nodes-base.webhook');
  assert.equal(hooks.length, 4);
  for (const h of hooks) {
    assert.equal(h.parameters.authentication, 'basicAuth', h.name);
    assert.ok(h.credentials && h.credentials.httpBasicAuth, `${h.name}: poświadczenie`);
  }
});

test('wysyłka Slack nie podąża za przekierowaniami i ma limit czasu', () => {
  const send = wf['05-deliver.json'].nodes.find((n) => n.name === 'Send Slack');
  assert.equal(send.parameters.options.redirect.redirect.followRedirects, false);
  assert.ok(send.parameters.options.timeout <= 15000);
});

test('niepowodzenia wysyłki są zapisywane w kolejce (mark_failed), a nie gubione', () => {
  const w = wf['05-deliver.json'];
  const names = w.nodes.map((n) => n.name);
  assert.ok(names.includes('Mark failed'));
  const to = (from, out) => (w.connections[from].main[out] || []).map((c) => c.node);
  assert.ok(to('Slack confirmed?', 1).includes('Failure reason'), 'Slack: odrzucone -> powód -> mark_failed');
  assert.ok(to('Email sent?', 1).includes('Failure reason'), 'mail: błąd -> powód -> mark_failed');
});

test('akcje zmieniające stan nie rozgałęziają się już na kolejki w n8n (powiadomienia zapisuje baza)', () => {
  const names = wf['03-team-tasks.json'].nodes.map((n) => n.name);
  assert.ok(!names.includes('Queue notifications'));
  const approve = wf['03-team-tasks.json'].nodes.find((n) => n.name === 'Approve order');
  assert.match(approve.parameters.jsonBody, /p_public_url/);
});

test('stan odbioru wiadomości: claim_deliveries dostaje flagi kanałów i listę dozwolonych adresów', () => {
  const claim = wf['05-deliver.json'].nodes.find((n) => n.name === 'Claim');
  for (const arg of ['p_limit', 'p_only_test', 'p_slack', 'p_email', 'p_allowlist']) assert.match(claim.parameters.jsonBody, new RegExp(arg));
});
