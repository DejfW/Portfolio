// Parsuje cenniki hurtowni (połączone pliki CSV z polecenia cat): supplier,material,price.
// Obsługuje BOM, CRLF, pola w cudzysłowie z przecinkami, puste linie, komentarze (#) i powtórzony nagłówek.
// Wiersze z brakującymi polami przechodzą dalej bez ceny, a baza zgłosi je jako błędne.
const raw = String($input.first().json.stdout || '').replace(/^﻿/, '').replace(/\r\n?/g, '\n');

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
  return out.map((c) => c.trim());
}

const rows = [];
for (const line of raw.split('\n')) {
  const t = line.trim();
  if (!t || t.startsWith('#')) continue;
  const [supplier, material, price] = parseLine(t);
  if (supplier.toLowerCase() === 'supplier' && String(material || '').toLowerCase() === 'material') continue;
  const row = { supplier, material };
  if (price !== undefined) row.price = price;
  rows.push(row);
}
return [{ json: { rows } }];
