// Parametry raportu tygodniowego. Z harmonogramu nie ma żadnego wejścia z zewnątrz; wywołanie przez
// webhook (/weekly-report) działa tylko w trybie testowym (ALLOW_LLM_MOCK=1) i może wskazać klucz raportu
// oraz atrapę odpowiedzi AI (nagłówek X-LLM-Mock, tak jak w przyjmowaniu zamówień).
const i = $input.first().json;
const viaWebhook = i.headers !== undefined;
const testMode = i.allowMock === '1';
const body = i.body && typeof i.body === 'object' ? i.body : {};

if (typeof i.projectDir !== 'string' || !i.projectDir || /["`$\\]/.test(i.projectDir)) throw new Error('INVALID_PROJECT_DIR');

let allowed = !viaWebhook || testMode;
// numer tygodnia ISO w strefie Warszawy: ten sam raport w tym samym tygodniu nie powstaje dwa razy
const d = new Date(new Date().toLocaleString('en-US', { timeZone: 'Europe/Warsaw' }));
const t = new Date(Date.UTC(d.getFullYear(), d.getMonth(), d.getDate()));
t.setUTCDate(t.getUTCDate() + 4 - (t.getUTCDay() || 7));
const week = Math.ceil(((t - Date.UTC(t.getUTCFullYear(), 0, 1)) / 86400000 + 1) / 7);
let key = `${t.getUTCFullYear()}-W${String(week).padStart(2, '0')}`;
if (viaWebhook && testMode && body.report_key !== undefined) {
  if (typeof body.report_key === 'string' && /^[A-Za-z0-9_-]{1,40}$/.test(body.report_key)) key = body.report_key;
  else allowed = false;
}
let mock = '';
const rawMock = viaWebhook && i.headers ? i.headers['x-llm-mock'] : undefined;
if (rawMock !== undefined && rawMock !== '') {
  if (testMode && typeof rawMock === 'string' && /^[a-z0-9-]+$/.test(rawMock)) mock = rawMock;
  else allowed = false;
}
return [{ json: { viaWebhook, allowed, key, mock, projectDir: i.projectDir } }];
