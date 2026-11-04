// Lightbox na natywnym <dialog>: Esc zamyka, klik w tło zamyka, fokus wraca na element otwierający.
import { el } from './dom.js';

let dialog, img, caption, opener;

function ensure() {
  if (dialog) return;
  img = el('img', { class: 'lightbox-img', attrs: { alt: '' } });
  caption = el('p', { class: 't-caption lightbox-caption' });
  const close = el('button', { class: 'btn btn-frosted lightbox-close', text: 'Close', attrs: { type: 'button' } });
  close.addEventListener('click', () => dialog.close());
  dialog = el('dialog', { class: 'lightbox', attrs: { 'aria-label': 'Enlarged image' } }, [close, img, caption]);
  dialog.addEventListener('click', (e) => { if (e.target === dialog) dialog.close(); });
  dialog.addEventListener('close', () => { if (opener && opener.isConnected) opener.focus(); opener = null; });
  document.body.append(dialog);
}

export function openLightbox({ src, alt, caption: text }) {
  ensure();
  opener = document.activeElement;
  img.src = src;
  img.alt = alt || '';
  caption.textContent = text || '';
  caption.hidden = !text;
  dialog.showModal();
}
