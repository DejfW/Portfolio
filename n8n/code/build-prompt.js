// Składa prompt dla AI z szablonu (n8n/prompts/parse-order.md, wstawianego przez n8n/build.mjs),
// katalogu z bazy i wiadomości klienta.
const n = $('Normalize').first().json;
const cfg = $('Config').first().json;
const catalog = $input.first().json;

const template = __PROMPT_TEMPLATE__;
const list = (arr) => (Array.isArray(arr) && arr.length ? arr.map((x) => `- ${x.name}`).join('\n') : '(brak)');

// Znacznik końca wiadomości wycinamy, żeby klient nie mógł "zamknąć" bloku danych w prompcie.
const message = n.message.split('WIADOMOSC>>>').join('').split('<<<WIADOMOSC').join('');

const prompt = template
  .split('{{PRODUCTS}}').join(list(catalog.products))
  .split('{{MATERIALS}}').join(list(catalog.materials))
  .split('{{MESSAGE}}').join(message);

return [{ json: { prompt, mock: n.mock, projectDir: cfg.projectDir } }];
