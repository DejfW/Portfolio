// Parsuje cenniki hurtowni (połączone pliki CSV z polecenia cat): supplier,material,price.
// Obsługuje BOM, CRLF, pola w cudzysłowie z przecinkami, puste linie, komentarze (#) i powtórzony nagłówek.
// Ścisłość: wiersz musi mieć dokładnie 3 kolumny i domknięte cudzysłowy. Inne wiersze przechodzą dalej jako
// {raw} bez ceny, więc baza zgłosi je jako błędne zamiast zapisać po cichu część danych.
const raw = String($input.first().json.stdout || '').replace(/^\uFEFF/, '').replace(/\r\n?/g, '\n');

function parseLine(line) {
  const out = [];
  let cur = '';
  let quoted = false;
  for (let k = 0; k < line.length; k++) {
    const ch = line[k];
    if (quoted) {
      if (ch === '"' && line[k + 1] === '"') { cur += '"'; k++; }
      else if (ch === '"') quoted = false;
      else cur += ch;
    } else if (ch === '"') quoted = true;
    else if (ch === ',') { out.push(cur); cur = ''; }
    else cur += ch;
  }
  out.push(cur);
  return { cols: out.map((c) => c.trim()), unterminated: quoted };
}

const rows = [];
for (const line of raw.split('\n')) {
  const t = line.trim();
  if (!t || t.startsWith('#')) continue;
  const { cols, unterminated } = parseLine(t);
  if (cols[0].toLowerCase() === 'supplier' && String(cols[1] || '').toLowerCase() === 'material') continue;
  if (unterminated || cols.length !== 3) { rows.push({ raw: t.slice(0, 200) }); continue; }
  rows.push({ supplier: cols[0], material: cols[1], price: cols[2] });
}
return [{ json: { rows } }];
