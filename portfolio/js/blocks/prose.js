import { el } from '../lib/dom.js';

export function render(block) {
  return el('div', { class: 'prose stack' }, block.paragraphs.map((t) => el('p', { class: 't-subheading', text: t })));
}
