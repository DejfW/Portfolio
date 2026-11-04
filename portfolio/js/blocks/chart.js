// Wykres słupkowy w HTML (responsywny); szerokości liczy scaleBars (w procentach).
import { el } from '../lib/dom.js';
import { scaleBars } from '../lib/chart-scale.js';

export function render(block) {
  const scaled = scaleBars(block.bars, { width: 100, barHeight: 1, gap: 0, labelWidth: 0 });
  const unit = block.unit ? ` ${block.unit}` : '';
  const rows = scaled.bars.map((b) => {
    const fill = el('div', { class: 'chart-fill' });
    fill.style.width = `${b.w}%`;
    return el('div', { class: 'chart-row' }, [
      el('div', { class: 'chart-label t-body', text: b.label }),
      el('div', { class: 'chart-track' }, [fill]),
      el('div', { class: 'chart-value t-body', text: `${b.value}${unit}` }),
    ]);
  });
  const summary = block.bars.map((b) => `${b.label}: ${b.value}${unit}`).join('; ');
  return el('div', { class: 'chart', attrs: { role: 'img', 'aria-label': summary } }, rows);
}
