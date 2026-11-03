// Waliduje odpowiedź AI i przygotowuje ładunek dla intake_order.
// Nic, co zwróci model, nie trafia do bazy bez sprawdzenia; wątpliwy wynik to route "needs_review".
const n = $('Normalize').first().json;
const catalog = $('Catalog').first().json;
const text = String($input.first().json.text || '');

const norm = (s) => String(s || '').normalize('NFC').trim().toLowerCase().replace(/\s+/g, ' ');
const index = (arr) => new Map((arr || []).map((x) => [norm(x.name), x.id]));
const products = index(catalog.products);
const materials = index(catalog.materials);

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

function out(route, kind, items, parsedExtra) {
  return [{
    json: {
      route,
      reason: parsedExtra.reason || null,
      missing: parsedExtra.missing || [],
      payload: {
        external_id: n.external_id,
        source: n.source,
        customer_email: n.customer_email,
        kind,
        raw_text: n.message,
        parsed: parsedExtra,
        route,
        items,
      },
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

if (parsed.missing !== undefined && !Array.isArray(parsed.missing)) return review('INVALID_MISSING', { llm: parsed });
const missing = (parsed.missing || []).filter((m) => typeof m === 'string' && m.trim()).map((m) => m.trim().slice(0, 200)).slice(0, 10);
if (missing.length > 0) return out('needs_info', kind, [], { missing, llm: parsed });

if (!Array.isArray(parsed.items) || parsed.items.length === 0) return review('NO_ITEMS', { llm: parsed });
if (parsed.items.length > 20) return review('TOO_MANY_ITEMS', { llm: parsed });

const items = [];
for (const it of parsed.items) {
  if (!it || typeof it !== 'object') return review('INVALID_ITEM', { llm: parsed });
  const qty = it.qty === undefined ? 1 : it.qty;
  if (!Number.isInteger(qty) || qty < 1 || qty > 1000) return review('INVALID_QTY', { llm: parsed });

  if (kind === 'catalog') {
    const id = typeof it.product === 'string' ? products.get(norm(it.product)) : undefined;
    if (!id) return review(`UNKNOWN_PRODUCT: ${String(it.product).slice(0, 100)}`, { llm: parsed });
    items.push({ product_id: id, qty });
  } else {
    const c = it.custom;
    if (!c || typeof c !== 'object') return review('INVALID_ITEM', { llm: parsed });
    const materialId = typeof c.material === 'string' ? materials.get(norm(c.material)) : undefined;
    if (!materialId) return review(`UNKNOWN_MATERIAL: ${String(c.material).slice(0, 100)}`, { llm: parsed });
    // zakres wymiarów sprawdza baza (INVALID_SPEC), tu tylko przekazujemy liczby
    items.push({
      custom_spec: { width_cm: c.width_cm, height_cm: c.height_cm, depth_cm: c.depth_cm, material_id: materialId },
      qty,
    });
  }
}

return out('ok', kind, items, { llm: parsed });
