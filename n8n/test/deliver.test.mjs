import test from 'node:test';
import assert from 'node:assert/strict';
import { runCode } from './harness.mjs';

const params = (i) => runCode('deliver-params', { input: [{ projectDir: '/p', testSinkPort: '18765', ...i }] })[0];
const SINK = 'http://127.0.0.1:18765/hook';

test('deliver-params: harmonogram jest dozwolony, a webhook tylko w trybie testowym z odbiornikiem', () => {
  assert.equal(params({}).allowed, true);
  assert.equal(params({ headers: {}, allowMock: '0', body: { slack_url: SINK } }).allowed, false);
  assert.equal(params({ headers: {}, allowMock: '1', body: { slack_url: SINK } }).allowed, true);
});

test('deliver-params: pusty webhook w trybie testowym nie uruchamia prawdziwej wysyłki (zarzut 6)', () => {
  for (const body of [{}, undefined, null, { slack_url: '' }, { x: 1 }]) {
    const p = params({ headers: {}, allowMock: '1', body, slackConfigured: true, emailDelivery: 'on' });
    assert.deepEqual([p.allowed, p.run], [false, false], `body: ${JSON.stringify(body)}`);
  }
});

test('deliver-params: odbiornik tylko dokładnie ten jeden adres, wtedy tylko wiadomości testowe (zarzut 7)', () => {
  const ok = params({ headers: {}, allowMock: '1', body: { slack_url: SINK }, emailDelivery: 'on' });
  assert.deepEqual([ok.allowed, ok.slackUrl, ok.onlyTest, ok.slackReady, ok.emailOn], [true, SINK, true, true, false]);
  for (const bad of ['http://127.0.0.1:8080/admin/reload', 'http://127.0.0.1:18765/inna', 'http://127.0.0.1:18765/hook/', 'http://127.0.0.1:18765/hook?x=1',
                     'http://evil.example/x', 'https://hooks.slack.com/services/T/B/x', 'http://localhost:18765/hook', 'http://127.0.0.1.evil.com:18765/hook', 5]) {
    assert.equal(params({ headers: {}, allowMock: '1', body: { slack_url: bad } }).allowed, false, `url: ${bad}`);
  }
});

test('deliver-params: w trybie testowym harmonogram nie dostarcza nic na prawdziwy kanał', () => {
  assert.equal(params({ allowMock: '0' }).run, true);
  assert.equal(params({ allowMock: '1' }).run, false);
  assert.equal(params({ headers: {}, allowMock: '1', body: { slack_url: SINK } }).run, true);
  assert.equal(params({ headers: {}, allowMock: '0', body: { slack_url: SINK } }).run, false);
});

test('deliver-params: bez konfiguracji nic nie jest gotowe, a maile są wyłączone', () => {
  const p = params({});
  assert.deepEqual([p.slackReady, p.emailOn], [false, false]);
  assert.equal(params({ slackConfigured: true }).slackReady, true);
  assert.equal(params({ emailDelivery: 'on' }).emailOn, true);
  assert.equal(params({ emailDelivery: 'yes' }).emailOn, false);
  assert.equal(params({ emailAllowlist: 'a@b.pl' }).allowlist, 'a@b.pl');
});

test('deliver-plan: trasa wynika z kanału, a nieznany kanał jest pomijany', () => {
  const r = runCode('deliver-plan', { input: [{ channel: 'slack', id: '1' }, { channel: 'email', id: '2' }, { channel: 'sms', id: '3' }] });
  assert.deepEqual(r.map((x) => x.route), ['slack:send', 'email:send', 'skip']);
  assert.deepEqual(r.map((x) => x.id), ['1', '2', '3']);
});

test('deliver-error: adresy URL (w tym sekretny webhook Slacka) nie trafiają do zapisanego błędu', () => {
  const run = (error) => runCode('deliver-error', { input: [{ error }] })[0].text;
  const t = run({ message: 'Request to https://hooks.slack.com/services/T0/B0/SECRET failed with 404' });
  assert.ok(!t.includes('SECRET') && !t.includes('hooks.slack.com'));
  assert.match(t, /<url>/);
  assert.equal(run(undefined), 'unknown');
  assert.equal(run('prosty tekst'), 'prosty tekst');
  assert.ok(run({ message: 'x'.repeat(500) }).length <= 200);
});
