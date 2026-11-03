import test from 'node:test';
import assert from 'node:assert/strict';
import { runCode } from './harness.mjs';

const params = (i) => runCode('deliver-params', { input: [{ projectDir: '/p', ...i }] })[0];

test('deliver-params: harmonogram jest dozwolony, a webhook tylko w trybie testowym', () => {
  assert.equal(params({}).allowed, true);
  assert.equal(params({ headers: {}, allowMock: '0' }).allowed, false);
  assert.equal(params({ headers: {}, allowMock: '1' }).allowed, true);
});

test('deliver-params: w trybie testowym harmonogram nie dostarcza nic na prawdziwy kanał', () => {
  assert.equal(params({ allowMock: '0' }).run, true);                       // produkcja: harmonogram działa
  assert.equal(params({ allowMock: '1' }).run, false);                      // tryb testowy: harmonogram wyłączony
  assert.equal(params({ headers: {}, allowMock: '1' }).run, true);          // na żądanie działa
  assert.equal(params({ headers: {}, allowMock: '0' }).run, false);         // webhook poza trybem testowym zablokowany
});

test('deliver-params: odbiornik testowy tylko na 127.0.0.1, a wtedy tylko wiadomości testowe', () => {
  const ok = params({ headers: {}, allowMock: '1', body: { slack_url: 'http://127.0.0.1:18765/hook' }, emailDelivery: 'on' });
  assert.deepEqual([ok.allowed, ok.slackUrl, ok.onlyTest, ok.slackReady, ok.emailOn], [true, 'http://127.0.0.1:18765/hook', true, true, false]);
  for (const bad of ['http://evil.example/x', 'https://hooks.slack.com/services/T/B/x', 'http://127.0.0.1.evil.com:80/x', 'http://localhost:80/x', 'http://127.0.0.1:80/../x', 5]) {
    assert.equal(params({ headers: {}, allowMock: '1', body: { slack_url: bad } }).allowed, false, `url: ${bad}`);
  }
  assert.equal(params({ headers: {}, allowMock: '0', body: { slack_url: 'http://127.0.0.1:80/x' } }).allowed, false);
});

test('deliver-params: bez konfiguracji nic nie jest gotowe, a maile są wyłączone', () => {
  const p = params({});
  assert.deepEqual([p.slackReady, p.emailOn], [false, false]);
  assert.equal(params({ slackConfigured: true }).slackReady, true);
  assert.equal(params({ emailDelivery: 'on' }).emailOn, true);
  assert.equal(params({ emailDelivery: 'yes' }).emailOn, false);
});

const plan = (p, msgs) => runCode('deliver-plan', { nodes: { 'Deliver params': { allowlist: '', ...p } }, input: msgs });
const email = (to) => ({ channel: 'email', id: '1', to });
const slack = { channel: 'slack', id: '2', text: 'x' };

test('deliver-plan: Slack wysyłamy tylko gdy jest adres', () => {
  assert.equal(plan({ slackReady: true }, [slack])[0].route, 'slack:send');
  const no = plan({ slackReady: false }, [slack])[0];
  assert.deepEqual([no.route, no.reason], ['skip', 'NO_SLACK_URL']);
});

test('deliver-plan: maile tylko na adresy z listy dozwolonych, domyślnie nic', () => {
  assert.equal(plan({ emailOn: false, allowlist: 'a@b.pl' }, [email('a@b.pl')])[0].reason, 'EMAIL_DELIVERY_OFF');
  const on = { emailOn: true, allowlist: ' Portfolio@Gmail.com , @firma.pl ' };
  assert.equal(plan(on, [email('portfolio@gmail.com')])[0].route, 'email:send');
  assert.equal(plan(on, [email('Jan@Firma.pl')])[0].route, 'email:send');
  for (const to of ['obcy@example.com', 'x@evilfirma.pl', 'x@firma.pl.evil.com', 'zly adres', '', undefined, 'a@b.pl, c@d.pl']) {
    const r = plan(on, [email(to)])[0];
    assert.equal(r.route, 'skip', `to: ${to}`);
  }
  assert.equal(plan({ emailOn: true, allowlist: '' }, [email('a@b.pl')])[0].route, 'skip');
});

test('deliver-plan: nieznany kanał jest pomijany, a wiele wiadomości zachowuje kolejność', () => {
  const r = plan({ slackReady: true, emailOn: false }, [slack, { channel: 'sms', id: '3' }, email('a@b.pl')]);
  assert.deepEqual(r.map((x) => x.route), ['slack:send', 'skip', 'skip']);
  assert.deepEqual(r.map((x) => x.id), ['2', '3', '1']);
});
