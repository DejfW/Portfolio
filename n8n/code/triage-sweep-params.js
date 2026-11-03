// Parametry naprawy przekazań do intake. Harmonogram działa zawsze; webhook /triage-sweep tylko w trybie testowym.
const i = $input.first().json;
const viaWebhook = i.headers !== undefined;
const testMode = i.allowMock === '1';
let allowed = !viaWebhook || testMode;
let intakeMock = '';
const raw = viaWebhook && i.headers ? i.headers['x-intake-mock'] : undefined;
if (raw !== undefined && raw !== '') {
  if (testMode && typeof raw === 'string' && /^[a-z0-9-]+$/.test(raw)) intakeMock = raw; else allowed = false;
}
return [{ json: { viaWebhook, allowed, intakeMock } }];
