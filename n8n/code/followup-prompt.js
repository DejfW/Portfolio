//@include textsafe
// Prompt dla AI dla każdej wyceny z listy. Etykiety pozycji to dane (mogą pochodzić z opisu klienta): usuwamy znaki
// sterujące, skracamy je i ograniczamy liczbę pozycji.
const p = $('Followup params').first().json;
const template = __PROMPT_TEMPLATE__;
// etykieta trafia i do promptu, i do maila: z adresem, linkiem lub znakami formatowania zastępujemy ją neutralną nazwą
const clean = (s) => {
  const t = String(s).replace(/[\u0000-\u001f\u007f<>]+/g, ' ').trim().slice(0, 80);
  return looksUnsafe(t) ? 'Pozycja z wyceny' : t;
};
return $input.all().map((it) => {
  const o = it.json;
  const lines = ((o.quote && o.quote.lines) || []).slice(0, 5);
  const products = lines.length ? lines.map((l) => `- ${clean(l.label)} × ${Number(l.qty) || 1}`).join('\n') : '- (meble z wyceny)';
  const prompt = template.split('{{NO}}').join(String(Number(o.followup_no))).split('{{PRODUCTS}}').join(products);
  return { json: { order_id: o.order_id, followup_no: o.followup_no, to: o.customer_email, total: o.quote && o.quote.total,
                   products, prompt, mock: p.mock, projectDir: p.projectDir, ref: o.order_id } };
});
