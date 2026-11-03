// Parametry sweepera: domyślnie zgłoszenia niedomknięte po 10 min uznajemy za utknięte,
// a brakujące maile uzupełniamy po 2 min. Wywołanie przez webhook (/sweep) działa tylko w trybie
// testowym (ALLOW_LLM_MOCK=1) i może skrócić te czasy; z harmonogramu nie ma żadnego wejścia z zewnątrz.
const i = $input.first().json;
const viaWebhook = i.headers !== undefined;
const testMode = i.allowMock === '1';
const body = i.body && typeof i.body === 'object' ? i.body : {};
const secs = (v, d) => (testMode && Number.isInteger(v) && v >= 0 && v <= 86400 ? v : d);
return [{
  json: {
    viaWebhook,
    allowed: !viaWebhook || testMode,
    stuckAfter: secs(body.stuck_after_seconds, 600),
    notifyAfter: secs(body.notify_after_seconds, 120),
  },
}];
