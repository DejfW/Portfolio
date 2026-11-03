// Parametry raportu magazynu. Domyślnie czytamy data/suppliers; wywołanie przez webhook (/stock-report)
// działa tylko w trybie testowym (ALLOW_LLM_MOCK=1) i może wskazać inny katalog w data/ oraz klucz raportu.
// Z harmonogramu nie ma żadnego wejścia z zewnątrz.
const i = $input.first().json;
const viaWebhook = i.headers !== undefined;
const testMode = i.allowMock === '1';
const body = i.body && typeof i.body === 'object' ? i.body : {};

// ścieżka projektu trafia do polecenia w cudzysłowie, więc odrzucamy znaki specjalne powłoki
if (typeof i.projectDir !== 'string' || !i.projectDir || /["`$\\]/.test(i.projectDir)) throw new Error('INVALID_PROJECT_DIR');

let allowed = !viaWebhook || testMode;
let dir = 'suppliers';
if (viaWebhook && testMode && body.dir !== undefined) {
  if (typeof body.dir === 'string' && /^[a-z0-9_-]{1,40}$/.test(body.dir)) dir = body.dir;
  else allowed = false;
}
const today = new Date().toLocaleDateString('sv-SE', { timeZone: 'Europe/Warsaw' });
let key = today;
if (viaWebhook && testMode && body.digest_key !== undefined) {
  if (typeof body.digest_key === 'string' && /^[A-Za-z0-9_-]{1,40}$/.test(body.digest_key)) key = body.digest_key;
  else allowed = false;
}
return [{ json: { viaWebhook, allowed, dir, key, today, projectDir: i.projectDir } }];
