// Parametry dostarczania. Z harmonogramu nie ma żadnego wejścia z zewnątrz. Webhook /deliver działa tylko
// w trybie testowym (ALLOW_LLM_MOCK=1) i może wskazać lokalny odbiornik zamiast Slacka (http://127.0.0.1:port/...);
// wtedy dostarczamy wyłącznie wiadomości oznaczone jako testowe, a maile nie są wysyłane.
const i = $input.first().json;
const viaWebhook = i.headers !== undefined;
const testMode = i.allowMock === '1';
const body = i.body && typeof i.body === 'object' ? i.body : {};

let allowed = !viaWebhook || testMode;
let slackUrl = '';
if (viaWebhook && testMode && body.slack_url !== undefined) {
  if (typeof body.slack_url === 'string' && /^http:\/\/127\.0\.0\.1:\d{2,5}\/[A-Za-z0-9_\/-]{0,60}$/.test(body.slack_url)) slackUrl = body.slack_url;
  else allowed = false;
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
    // wysyłka maili jest domyślnie wyłączona; po włączeniu idzie tylko na adresy z listy dozwolonych
    emailOn: i.emailDelivery === 'on' && !onlyTest,
    allowlist: String(i.emailAllowlist || ''),
  },
}];
