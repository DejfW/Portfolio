// Prompt klasyfikatora: lista FAQ jest wbudowana przy buildzie (data/faq.md), a temat i treść wiadomości to dane od klienta
// (ograniczone długością, bez znaków sterujących).
const n = $('Triage normalize').first().json;
const template = __PROMPT_TEMPLATE__;
const faq = __FAQ__;
const clean = (s) => String(s).replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]+/g, ' ');
// jedno przejście: wstawione dane (temat, treść) nie są ponownie przeszukiwane pod kątem znaczników szablonu
const vals = { FAQ: faq, SUBJECT: clean(n.subject).slice(0, 300), MESSAGE: clean(n.message).slice(0, 5000) };
const prompt = template.replace(/\{\{(FAQ|SUBJECT|MESSAGE)\}\}/g, (_, k) => vals[k]);
if (prompt.length > 60000) throw new Error('PROMPT_TOO_LARGE');
return [{ json: { prompt, mock: n.mock, projectDir: $('Config').first().json.projectDir } }];
