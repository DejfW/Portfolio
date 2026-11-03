// Składa mail z przypomnieniem. Stałe są tylko temat i stopka; wstęp pisze AI, ale tylko gdy jego odpowiedź jest
// bezpieczna (dokładnie 3 zdania, bez linków, adresów e-mail i znaków formatowania, rozsądna długość). W innym razie idzie stały szablon,
// więc awaria albo nadużycie modelu nie zatrzymuje przypomnień ani nie wysyła obcych linków klientowi.
//@include page
//@include textsafe
const prompts = $('Followup prompt').all();
// wyniki AI dopasowujemy po znaczniku zamówienia (ref), a nie po kolejności: błąd jednego wywołania nie może przesunąć reszty
const byRef = {};
for (const x of $input.all()) if (x.json && typeof x.json.ref === 'string') byRef[x.json.ref] = x.json;
const FALLBACK = {
  1: 'Przypominamy o przygotowanej dla Państwa wycenie mebli z naszej pracowni. Chętnie odpowiemy na wszelkie pytania i pomożemy dopasować projekt do Państwa potrzeb. Jeśli coś wymaga zmiany, wystarczy dać nam znać.',
  2: 'To ostatnie przypomnienie o wycenie mebli przygotowanej dla Państwa w naszej pracowni. Jeśli nadal są Państwo zainteresowani, chętnie wprowadzimy zmiany i odpowiemy na pytania. W przeciwnym razie zamkniemy wycenę w naszym systemie.',
};
const SUBJECT = { 1: 'Przypomnienie o wycenie mebli', 2: 'Ostatnie przypomnienie o wycenie mebli' };
const safe = (t) => {
  const s = String(t || '').replace(/[\u0000-\u001f\u007f]+/g, ' ').replace(/\s+/g, ' ').trim();
  if (s.length < 30 || s.length > 700) return null;
  if (looksUnsafe(s) || looksRefusal(s)) return null;
  // prompt prosi o dokładnie 3 zdania o wycenie; inny kształt idzie do stałego szablonu
  if ((s.match(/[.!?](\s|$)/g) || []).length !== 3 || !/wycen/i.test(s)) return null;
  return s;
};
return prompts.map((pr) => {
  const o = pr.json;
  const l = byRef[o.order_id] || {};
  const no = Number(o.followup_no) === 2 ? 2 : 1;
  const intro = (l.ok && safe(l.text)) || FALLBACK[no];
  const body = `Dzień dobry,\n\n${intro}\n\nWycena wstępna: ${pln(o.total)}\n${o.products}\n\n` +
    `Aby przejść dalej albo zmienić wycenę, wystarczy odpowiedzieć na tego maila.\n\nPozdrawiamy`;
  return { json: { order_id: o.order_id, followup_no: no, subject: SUBJECT[no], body } };
});
