import { el } from '../lib/dom.js';
import { openLightbox } from '../lib/lightbox.js';

function imageFigure(item, base) {
  const src = `${base}${item.src}`;
  const btn = el('button', { class: 'media-open', attrs: { type: 'button', 'aria-label': `Enlarge: ${item.alt}` } }, [
    el('img', { attrs: { src, alt: item.alt, loading: 'lazy', decoding: 'async' } }),
  ]);
  btn.addEventListener('click', () => openLightbox({ src, alt: item.alt, caption: item.caption }));
  return btn;
}

function videoFigure(item, base) {
  const attrs = { src: `${base}${item.src}`, controls: '', preload: 'metadata', playsinline: '' };
  if (item.poster) attrs.poster = `${base}${item.poster}`;
  return el('video', { class: 'media-video', attrs });
}

export function render(block, ctx) {
  if (!block.items.length) {
    return el('div', { class: 'media-placeholder' }, [el('p', { class: 't-body', text: 'Recordings and screenshots will appear here.' })]);
  }
  return el('div', { class: 'gallery' }, block.items.map((item) => {
    const fig = el('figure', { class: 'media' }, [item.type === 'video' ? videoFigure(item, ctx.base) : imageFigure(item, ctx.base)]);
    if (item.caption) fig.append(el('figcaption', { class: 't-caption', text: item.caption }));
    return fig;
  }));
}
