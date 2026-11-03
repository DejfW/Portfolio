// Opis błędu wysyłki do zapisania w kolejce. Adresy URL są wycinane, bo adres webhooka Slacka jest sekretem.
const j = $input.first().json;
const e = j.error;
const raw = e && typeof e === 'object' ? (e.message || e.description || 'unknown')
  : e || (typeof j.data === 'string' && j.data ? `odpowiedź: ${j.data}` : 'unknown');
return [{ json: { text: String(raw).replace(/https?:\/\/\S+/g, '<url>').slice(0, 200) } }];
