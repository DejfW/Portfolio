// Prompt dla AI: dane sprzedaży z bazy i prośba o krótkie podsumowanie. Nazwy produktów to dane, nie polecenia:
// skracamy je, usuwamy znaki sterujące i ograniczamy liczbę wierszy, żeby prompt miał ograniczony rozmiar.
const p = $('Report params').first().json;
const data = $input.first().json;
const template = __PROMPT_TEMPLATE__;
const clean = (s) => String(s).replace(/[\u0000-\u001f\u007f<>]+/g, ' ').trim().slice(0, 60);
const rows = (a) => (Array.isArray(a) && a.length
  ? a.slice(0, 10).map((r) => `- ${clean(r.name)}: ${Number(r.qty)} szt., ${r.revenue === null || r.revenue === undefined ? 'brak wyceny' : Number(r.revenue).toFixed(2) + ' zł'}`).join('\n')
  : '(brak sprzedaży)');
const prompt = template
  .split('{{WEEK}}').join(rows(data.week))
  .split('{{MONTH}}').join(rows(data.month));
return [{ json: { prompt, mock: p.mock, projectDir: p.projectDir } }];
