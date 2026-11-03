// Składa wiadomość Slack: tabele bestsellerów liczy baza, AI dopisuje tylko krótkie podsumowanie.
// Gdy AI zawiedzie, raport i tak wychodzi (z adnotacją), bo liczby są najważniejsze.
//@include page
const p = $('Report params').first().json;
const data = $('Report data').first().json;
const llm = $input.first().json;

const list = (a) => (Array.isArray(a) ? a : []);
// Nazwa trafia do tabeli skrócona i bez znaków formatowania Slacka, żeby jedna długa nazwa nie wypchnęła reszty raportu.
const name = (s) => slackEsc(String(s).replace(/[\u0000-\u001f\u007f*_~`>|]+/g, ' ').trim().slice(0, 60));
// przychód nieznany (brak aktualnej ceny materiału) pokazujemy wprost, a nie jako 0 zł
const revenue = (v) => (v === null || v === undefined ? 'brak wyceny' : pln(v));
const table = (title, rows) => {
  const r = list(rows).slice(0, 5);
  if (!r.length) return `*${title}:* brak sprzedaży`;
  return `*${title}:*\n` + r.map((x, n) => `${n + 1}. ${name(x.name)}: ${Number(x.qty)} szt., ${revenue(x.revenue)}`).join('\n');
};
const summary = llm.ok ? slackEsc(String(llm.text).replace(/\s+/g, ' ').trim()).slice(0, 900) : '';
const text = [
  `📈 Raport tygodniowy (${p.key})`,
  table('Ostatnie 7 dni', data.week),
  table('Ostatnie 30 dni', data.month),
  summary ? `*Podsumowanie:* ${summary}` : '_Podsumowanie AI niedostępne._',
].join('\n\n').slice(0, 2900);

return [{ json: { p: [{ channel: 'slack', kind: 'weekly_report', dedupe_key: `weekly-report:${p.key}`, text }] } }];
