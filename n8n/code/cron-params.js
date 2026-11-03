// Parametry zadań cyklicznych (powiadomienia o statusie, prośby o opinię). Harmonogram działa zawsze; wywołanie przez
// webhook jest dozwolone tylko w trybie testowym (ALLOW_LLM_MOCK=1) i może wskazać adres opinii (review_url, tylko https).
// Wartości z konfiguracji (Config): reviewUrl z GOOGLE_REVIEW_URL, statusUrl ze STATUS_URL.
const i = $input.first().json;
const viaWebhook = i.headers !== undefined;
const testMode = i.allowMock === '1';
const body = i.body && typeof i.body === 'object' ? i.body : {};
let allowed = !viaWebhook || testMode;
let reviewUrl = typeof i.reviewUrl === 'string' && i.reviewUrl ? i.reviewUrl : null;
if (viaWebhook && testMode && body.review_url !== undefined) {
  if (typeof body.review_url === 'string' && body.review_url.length <= 300) reviewUrl = body.review_url;
  else allowed = false;
}
return [{ json: { viaWebhook, allowed, reviewUrl, statusUrl: typeof i.statusUrl === 'string' && i.statusUrl ? i.statusUrl : null } }];
