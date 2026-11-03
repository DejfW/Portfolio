// Parametry przypomnień o wycenach. Harmonogram działa zawsze; wywołanie przez webhook (/followup-run) jest dozwolone
// tylko w trybie testowym (ALLOW_LLM_MOCK=1) i może wskazać atrapę odpowiedzi AI (nagłówek X-LLM-Mock).
const i = $input.first().json;
const viaWebhook = i.headers !== undefined;
const testMode = i.allowMock === '1';
if (typeof i.projectDir !== 'string' || !i.projectDir || /["`$\\]/.test(i.projectDir)) throw new Error('INVALID_PROJECT_DIR');
let allowed = !viaWebhook || testMode;
let mock = '';
const rawMock = viaWebhook && i.headers ? i.headers['x-llm-mock'] : undefined;
if (rawMock !== undefined && rawMock !== '') {
  if (testMode && typeof rawMock === 'string' && /^[a-z0-9-]+$/.test(rawMock)) mock = rawMock;
  else allowed = false;
}
return [{ json: { viaWebhook, allowed, mock, projectDir: i.projectDir } }];
