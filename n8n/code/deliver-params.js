// Parametry dostarczania. Z harmonogramu nie ma żadnego wejścia z zewnątrz. Webhook /deliver działa wyłącznie
// w trybie testowym (ALLOW_LLM_MOCK=1) i MUSI wskazać dokładnie jeden lokalny odbiornik (http://127.0.0.1:<TEST_SINK_PORT>/hook);
// bez niego, albo z innym adresem, jest odrzucany. Wtedy dostarczamy wyłącznie wiadomości oznaczone jako testowe,
// a maile nie są wysyłane, więc żadne żądanie z zewnątrz nie uruchomi prawdziwej wysyłki.
const i = $input.first().json;
const viaWebhook = i.headers !== undefined;
const testMode = i.allowMock === '1';
const body = i.body && typeof i.body === 'object' ? i.body : {};

let allowed = !viaWebhook;
let slackUrl = '';
if (viaWebhook && testMode) {
  const expected = `http://127.0.0.1:${i.testSinkPort}/hook`;
  if (typeof body.slack_url === 'string' && body.slack_url === expected) { slackUrl = expected; allowed = true; }
}
const onlyTest = slackUrl !== '';
// W trybie testowym harmonogram niczego nie dostarcza: testy chwilowo wstawiają do kolejek wiadomości,
// które nie mogą trafić na prawdziwy kanał Slack. Dostarczanie działa wtedy tylko na żądanie (webhook).
const run = allowed && (viaWebhook || !testMode);
return [{
  json: {
    viaWebhook,
    allowed,
    run,
    slackUrl,
    onlyTest,
    slackReady: onlyTest || i.slackConfigured === true,
    // wysyłka maili jest domyślnie wyłączona; po włączeniu baza wydaje tylko adresy z listy dozwolonych
    emailOn: i.emailDelivery === 'on' && !onlyTest,
    allowlist: String(i.emailAllowlist || ''),
  },
}];
