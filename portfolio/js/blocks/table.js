import { el } from '../lib/dom.js';

export function render(block) {
  const head = el('tr', {}, block.columns.map((c) => el('th', { text: c, attrs: { scope: 'col' } })));
  const rows = block.rows.map((r) => el('tr', {}, r.map((c, i) => el(i === 0 ? 'th' : 'td', { text: c, attrs: i === 0 ? { scope: 'row' } : {} }))));
  const table = el('table', { class: 'data-table' }, [el('thead', {}, [head]), el('tbody', {}, rows)]);
  return el('div', { class: 'table-wrap', attrs: { tabindex: '0', role: 'region', 'aria-label': block.title || 'Table' } }, [table]);
}
