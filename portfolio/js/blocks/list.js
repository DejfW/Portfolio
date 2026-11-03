import { el } from '../lib/dom.js';

export function render(block) {
  return el('div', { class: 'decision-grid' }, block.items.map((it) => el('div', { class: 'card' }, [
    el('h3', { class: 't-heading-sm', text: it.title }),
    el('p', { class: 't-body card-text', text: it.text }),
  ])));
}
