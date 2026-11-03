// Waliduje odpowiedź AI i przygotowuje ładunek dla intake_complete.
// Nic, co zwróci model, nie trafia do bazy bez sprawdzenia: każdy nieoczekiwany kształt danych
// to route "needs_review", a rzeczywiste braki po stronie klienta to "needs_info".
const n = $('Normalize').first().json;
const catalog = $('Catalog').first().json;
const text = String($input.first().json.text || '');

const AMBIGUOUS = '__ambiguous__';
const norm = (s) => s.normalize('NFC').trim().toLowerCase().replace(/\s+/g, ' ');

// Indeks nazwa -> id. Dwa różne id pod jedną znormalizowaną nazwą (np. "Stół" i "STÓŁ")
// oznaczamy jako niejednoznaczne, żeby model nie wybrał cicho złego produktu.
function index(arr) {
  const m = new Map();
  for (const x of Array.isArray(arr) ? arr : []) {
    const k = norm(String(x.name));
    m.set(k, m.has(k) && m.get(k) !== x.id ? AMBIGUOUS : x.id);
  }
  return m;
}
const products = index(catalog.products);
const materials = index(catalog.materials);

// Bezpieczny podgląd dowolnej wartości do komunikatu (obiekty z nadpisanym toString nie przewracają kodu).
function short(v) {
  try {
    const s = typeof v === 'string' ? v : JSON.stringify(v);
    return String(s === undefined ? typeof v : s).slice(0, 100);
  } catch (e) {
    return typeof v;
  }
}

function lookup(map, name, what) {
  if (typeof name !== 'string' || !name.trim()) return { error: `INVALID_${what}_NAME: ${short(name)}` };
  const id = map.get(norm(name));
  if (id === undefined) return { error: `UNKNOWN_${what}: ${short(name)}` };
  if (id === AMBIGUOUS) return { error: `AMBIGUOUS_${what}: ${short(name)}` };
  return { id };
}

function extractJson(t) {
  const fenced = t.match(/```(?:json)?\s*([\s\S]*?)```/i);
  const src = fenced ? fenced[1] : t;
  const a = src.indexOf('{');
  const b = src.lastIndexOf('}');
  if (a === -1 || b <= a) return null;
  try {
    return JSON.parse(src.slice(a, b + 1));
  } catch (e) {
    return null;
  }
}

function out(route, kind, items, parsed) {
  return [{
    json: {
      route,
      reason: parsed.reason || null,
      missing: parsed.missing || [],
      // tylko to, czego potrzebuje intake_complete; dane zgłoszenia są już w bazie od intake_receive
      payload: { kind, route, items, parsed },
    },
  }];
}

const review = (reason, extra = {}) => out('needs_review', 'catalog', [], { reason, ...extra });

const parsed = extractJson(text);
if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
  return review('LLM_INVALID_JSON', { llm_text: text.slice(0, 2000) });
}
if (parsed.kind !== 'catalog' && parsed.kind !== 'custom') return review('INVALID_KIND', { llm: parsed });
const kind = parsed.kind;

// braki zgłoszone przez model: tablica niepustych tekstów albo błąd schematu
let missing = [];
if (parsed.missing !== undefined) {
  if (!Array.isArray(parsed.missing) || parsed.missing.some((m) => typeof m !== 'string' || !m.trim())) {
    return review('INVALID_MISSING', { llm: parsed });
  }
  missing = parsed.missing.map((m) => m.trim().slice(0, 200)).slice(0, 10);
}
if (missing.length > 0) return out('needs_info', kind, [], { missing, llm: parsed });

if (!Array.isArray(parsed.items) || parsed.items.length === 0) return review('NO_ITEMS', { llm: parsed });
if (parsed.items.length > 20) return review('TOO_MANY_ITEMS', { llm: parsed });

const items = [];
const missingQty = [];
for (const it of parsed.items) {
  if (!it || typeof it !== 'object' || Array.isArray(it)) return review('INVALID_ITEM', { llm: parsed });

  let name;
  let found;
  if (kind === 'catalog') {
    name = it.product;
    found = lookup(products, name, 'PRODUCT');
  } else {
    if (!it.custom || typeof it.custom !== 'object' || Array.isArray(it.custom)) return review('INVALID_ITEM', { llm: parsed });
    name = it.custom.material;
    found = lookup(materials, name, 'MATERIAL');
  }
  if (found.error) return review(found.error, { llm: parsed });

  // ilość jest wymagana: jej brak to pytanie do klienta, a nie domyślna jedynka
  if (it.qty === undefined) {
    missingQty.push(`Ilość: ${name.trim().slice(0, 100)}`);
    continue;
  }
  if (!Number.isInteger(it.qty) || it.qty < 1 || it.qty > 1000) return review('INVALID_QTY', { llm: parsed });

  if (kind === 'catalog') {
    items.push({ product_id: found.id, qty: it.qty });
  } else {
    const c = it.custom;
    // zakres wymiarów sprawdza baza (INVALID_SPEC), tu tylko przekazujemy wartości
    items.push({
      custom_spec: { width_cm: c.width_cm, height_cm: c.height_cm, depth_cm: c.depth_cm, material_id: found.id },
      qty: it.qty,
    });
  }
}
if (missingQty.length > 0) return out('needs_info', kind, [], { missing: missingQty.slice(0, 10), llm: parsed });

return out('ok', kind, items, { llm: parsed });
