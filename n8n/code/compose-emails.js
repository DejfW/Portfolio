// Składa maile ze stanu zamówienia w bazie (wynik notification_context). Ten sam kod obsługuje
// przepływ normalny i naprawę po awarii (sweeper), więc brakujące maile da się zawsze odtworzyć.
// Zwraca elementy {order_id, kind, to, subject, body}; kolejne węzły dopisują je do email_outbox
// (unikalnie po zamówieniu i rodzaju), a rodzaje już istniejące pomijamy tutaj.
// Treść jest zwykłym tekstem. Przy wysyłce w HTML trzeba ją escape'ować (zawiera tekst od klienta).
const cfg = $('Config').first().json;
const pln = (x) => `${Number(x).toFixed(2).replace('.', ',')} zł`;
const mails = [];

for (const item of $input.all()) {
  const c = item.json;
  if (!c || !c.order_id) continue; // brak zamówienia o takim id

  const has = new Set(c.existing_kinds || []);
  const add = (kind, to, subject, body) => {
    if (!has.has(kind)) mails.push({ json: { order_id: c.order_id, kind, to, subject, body } });
  };
  const email = c.customer_email;
  const excerpt = String(c.raw_text || '').slice(0, 300);

  if (c.status === 'quoted' && c.quote && c.quote.total !== undefined) {
    const lines = (c.quote.lines || []).map((l) => `- ${l.label} × ${l.qty}`).join('\n');
    add('customer_quote', email, 'Wstępna wycena Twojego zamówienia',
      `Dzień dobry,\n\ndziękujemy za zapytanie. Pozycje w wycenie:\n${lines}\n\n` +
      `Wstępna wycena: ${pln(c.quote.total)}\n\n` +
      'To wycena wstępna, wyliczona automatycznie. Ostateczną cenę i termin potwierdzimy po weryfikacji zamówienia.\n\n' +
      'Pozdrawiamy,\nStolarnia');
    add('owner_alert', cfg.ownerEmail, `Nowe zamówienie do zatwierdzenia: ${email} (${pln(c.quote.total)})`,
      `Klient: ${email}\nŹródło: ${c.source}\nWycena wstępna: ${pln(c.quote.total)}\n\n` +
      `Wiadomość klienta:\n${excerpt}\n\nZatwierdź i zleć zadanie: ${cfg.publicUrl}/webhook/approve?order_id=${c.order_id}`);
  } else if (c.status === 'needs_info') {
    const list = (c.missing || []).map((m) => `- ${m}`).join('\n');
    add('needs_info', email, 'Potrzebujemy kilku informacji do wyceny',
      `Dzień dobry,\n\ndziękujemy za wiadomość. Żeby przygotować wycenę, prosimy jeszcze o:\n${list}\n\n` +
      'Wystarczy odpowiedzieć na tego maila.\n\nPozdrawiamy,\nStolarnia');
  } else if (c.status === 'needs_review') {
    add('owner_alert', cfg.ownerEmail, `Zamówienie do sprawdzenia: ${email}`,
      `Automat nie wycenił tego zamówienia. Powód: ${c.reason || c.status}\n\nKlient: ${email}\nŹródło: ${c.source}\n\n` +
      `Wiadomość klienta:\n${excerpt}`);
  }
}

return mails;
