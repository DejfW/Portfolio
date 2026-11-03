// Składa maile po przyjęciu zamówienia. Zwraca 0-2 elementów {order_id, kind, to, subject, body};
// kolejne węzły dopisują je do email_outbox (unikalnie po zamówieniu i rodzaju).
const cfg = $('Config').first().json;
const v = $('Validate').first().json;
const r = $input.first().json;

if (!r.created) return []; // zamówienie już istniało, maile poszły przy pierwszym przyjęciu

const pln = (x) => `${Number(x).toFixed(2).replace('.', ',')} zł`;
const excerpt = String(v.payload.raw_text).slice(0, 300);
const email = v.payload.customer_email;
const link = `${cfg.publicUrl}/webhook/approve?order_id=${r.order_id}`;
const mails = [];
const add = (kind, to, subject, body) => mails.push({ json: { order_id: r.order_id, kind, to, subject, body } });

if (r.status === 'quoted') {
  const lines = (r.quote.lines || []).map((l) => `- ${l.label} × ${l.qty}`).join('\n');
  add('customer_quote', email, 'Wstępna wycena Twojego zamówienia',
    `Dzień dobry,\n\ndziękujemy za zapytanie. Pozycje w wycenie:\n${lines}\n\n` +
    `Wstępna wycena: ${pln(r.quote.total)}\n\n` +
    'To wycena wstępna, wyliczona automatycznie. Ostateczną cenę i termin potwierdzimy po weryfikacji zamówienia.\n\n' +
    'Pozdrawiamy,\nStolarnia');
  add('owner_alert', cfg.ownerEmail, `Nowe zamówienie do zatwierdzenia: ${email} (${pln(r.quote.total)})`,
    `Klient: ${email}\nŹródło: ${v.payload.source}\nWycena wstępna: ${pln(r.quote.total)}\n\n` +
    `Wiadomość klienta:\n${excerpt}\n\nZatwierdź i zleć zadanie: ${link}`);
} else if (r.status === 'needs_info') {
  const list = v.missing.map((m) => `- ${m}`).join('\n');
  add('needs_info', email, 'Potrzebujemy kilku informacji do wyceny',
    `Dzień dobry,\n\ndziękujemy za wiadomość. Żeby przygotować wycenę, prosimy jeszcze o:\n${list}\n\n` +
    'Wystarczy odpowiedzieć na tego maila.\n\nPozdrawiamy,\nStolarnia');
} else {
  const reason = (r.quote && r.quote.error) || v.reason || r.status;
  add('owner_alert', cfg.ownerEmail, `Zamówienie do sprawdzenia: ${email}`,
    `Automat nie wycenił tego zamówienia. Powód: ${reason}\n\nKlient: ${email}\nŹródło: ${v.payload.source}\n\n` +
    `Wiadomość klienta:\n${excerpt}`);
}

return mails;
