// Składa podsumowanie dla właściciela: wynik importu cen i materiały do zamówienia.
// Wiadomość powstaje tylko wtedy, gdy jest o czym informować; klucz deduplikacji chroni przed dublem.
//@include page
const params = $('Stock params').first().json;
const imp = $('Import prices').first().json;
const rep = $input.first().json;

const list = (a) => (Array.isArray(a) ? a : []);
const lines = [];
const issues = [];

if (imp.error) issues.push(`Import cenników nie powiódł się (${imp.error}).`);
if (list(imp.unknown_suppliers).length) issues.push(`Nieznane hurtownie: ${list(imp.unknown_suppliers).map(slackEsc).join(', ')}.`);
if (list(imp.unknown_materials).length) issues.push(`Nieznane materiały: ${list(imp.unknown_materials).map(slackEsc).join(', ')}.`);
if (list(imp.invalid).length) issues.push(`Błędnych wierszy: ${list(imp.invalid).length}.`);
if (!imp.error && Number(imp.updated) === 0) issues.push('Żadna cena nie została zaktualizowana (brak plików albo same błędne wiersze).');

const items = list(rep.items);
for (const it of items) {
  const where = it.best_supplier ? `najtaniej: ${slackEsc(it.best_supplier)} po ${pln(it.best_price)}` : 'brak aktualnej ceny';
  lines.push(`• ${slackEsc(it.name)}: dostępne ${Number(it.available)}, do zamówienia ${Number(it.to_order)}, ${where}`);
}
const unpriced = list(rep.unpriced);

if (!items.length && !issues.length) return [{ json: { p: [] } }];

const text = [
  `📦 Raport magazynu (${params.today})`,
  imp.error ? null : `Ceny hurtowni zaktualizowane: ${Number(imp.updated) || 0}.`,
  ...issues.map((x) => `⚠️ ${x}`),
  items.length ? `Do zamówienia (${items.length}):\n${lines.join('\n')}` : null,
  unpriced.length ? `Bez aktualnej ceny w hurtowniach: ${unpriced.map(slackEsc).join(', ')}.` : null,
].filter(Boolean).join('\n');

return [{ json: { p: [{ channel: 'slack', kind: 'stock_digest', dedupe_key: `stock-digest:${params.key}`, text: text.slice(0, 2900) }] } }];
