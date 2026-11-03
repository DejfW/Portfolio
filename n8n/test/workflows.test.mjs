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

test('triage skrzynki nigdy nie wysyła poczty ani nie dotyka skrzynki (tylko szkice dla właściciela w bazie i na Slacku)', () => {
  const types = wf['11-inbox-triage.json'].nodes.map((n) => n.type);
  for (const t of types) assert.ok(!/emailSend|gmail|smtp|imap|microsoftOutlook/i.test(t), `niedozwolony węzeł: ${t}`);
});

test('triage: sekret intake przekazywany wyrażeniem, a nie wartością, a przekazanie nie ma sztywnego tokenu', () => {
  const fwd = wf['11-inbox-triage.json'].nodes.find((n) => n.name === 'Forward to intake');
  const hdr = Object.fromEntries(fwd.parameters.headerParameters.parameters.map((h) => [h.name, h.value]));
  assert.match(hdr['X-Intake-Token'], /\$env\.INTAKE_TOKEN/);
  assert.equal(fwd.onError, 'continueRegularOutput');
});

test('workflow salonowy nie zapisuje danych wykonań (żądanie niesie token salonu)', () => {
  const s = wf['13-showroom.json'].settings;
  assert.equal(s.saveDataSuccessExecution, 'none');
  assert.equal(s.saveDataErrorExecution, 'none');
  assert.equal(s.saveManualExecutions, false);
  assert.equal(s.saveExecutionProgress, false);
});

test('publiczne webhooki salonowe i kalkulatora nie przekazują sekretów dalej do odpowiedzi', () => {
  const text = JSON.stringify(wf['13-showroom.json'].nodes.filter((n) => n.type.endsWith('respondToWebhook')));
  assert.ok(!/access_token|salesperson_email/.test(text), 'odpowiedzi nie zawierają tokenu ani adresu handlowca');
});

test('cykliczne powiadomienia (10, 12) wołają tylko funkcje SQL, a webhooki testowe są chronione trybem testowym', () => {
  for (const [f, fn] of [['10-status-notify.json', 'notify_status_events'], ['12-review-request.json', 'send_review_requests']]) {
    const w = wf[f];
    const run = w.nodes.find((n) => n.name === 'Run');
    assert.match(run.parameters.url, new RegExp(`/rpc/${fn}`), f);
    const hook = w.nodes.find((n) => n.type.endsWith('webhook'));
    assert.equal(hook.parameters.authentication, undefined, `${f}: webhook testowy bez logowania, ale za bramką trybu testowego`);
    assert.ok(w.nodes.some((n) => n.name === 'Cron params') && w.nodes.some((n) => n.name === 'Forbidden'), `${f}: bramka trybu testowego`);
    assert.ok(w.nodes.every((n) => !/emailSend|gmail|smtp/i.test(n.type)), `${f}: maile tylko przez kolejkę w bazie`);
  }
});
