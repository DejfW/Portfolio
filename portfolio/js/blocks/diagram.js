import { el } from '../lib/dom.js';
import { openLightbox } from '../lib/lightbox.js';

export function render(block, ctx) {
  const src = `${ctx.base}${block.src}`;
  const btn = el('button', { class: 'media-open diagram-open', attrs: { type: 'button', 'aria-label': `Enlarge diagram: ${block.alt}` } }, [
    el('img', { attrs: { src, alt: block.alt, loading: 'lazy', decoding: 'async' } }),
  ]);
  btn.addEventListener('click', () => openLightbox({ src, alt: block.alt, caption: block.caption }));
  const fig = el('figure', { class: 'media diagram' }, [btn]);
  if (block.caption) fig.append(el('figcaption', { class: 't-caption', text: block.caption }));
  return fig;
}
