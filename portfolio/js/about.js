// Sekcja About: bio, highlights, umiejętności i linki (w tym opcjonalne CV).
import { el } from './lib/dom.js';
import { safeLinks } from './lib/schema.js';

export function linkButtons(site, cls = 'btn btn-ghost plain') {
  const items = [...safeLinks(site.links)];
  if (site.cv && /\.pdf$/i.test(String(site.cv.url))) items.push({ label: site.cv.label, url: site.cv.url, internal: true });
  return items.map((l) => {
    const a = el('a', { class: cls, text: l.label, attrs: { href: l.url } });
    if (!l.internal && /^https?:/i.test(l.url)) { a.setAttribute('target', '_blank'); a.setAttribute('rel', 'noopener noreferrer'); }
    if (l.internal) a.setAttribute('download', '');
    return a;
  });
}

export function renderAbout(site, section, container) {
  const about = site.about;
  const hasContent = about || (site.highlights && site.highlights.length) || (site.skills && site.skills.length);
  if (!hasContent) { section.hidden = true; return false; }

  const text = el('div', { class: 'about-text' });
  text.append(el('h2', { class: 't-heading-lg', text: (about && about.title) || 'About me', attrs: { id: 'about-title' } }));
  for (const p of (about && about.paragraphs) || []) text.append(el('p', { class: 't-subheading', text: p }));
  const buttons = linkButtons(site);
  if (buttons.length) text.append(el('div', { class: 'btn-row' }, buttons));

  const side = el('div', { class: 'about-highlights' });
  for (const h of site.highlights || []) {
    side.append(el('div', { class: 'card-glow' }, [el('h3', { class: 't-heading-sm', text: h.title }), el('p', { class: 't-body', text: h.text })]));
  }
  if (site.skills && site.skills.length) {
    const skills = el('div', { class: 'skills' });
    for (const g of site.skills) {
      skills.append(el('div', {}, [
        el('p', { class: 't-label', text: g.group }),
        el('div', { class: 'pill-list' }, g.items.map((i) => el('span', { class: 'pill', text: i }))),
      ]));
    }
    side.append(skills);
  }
  container.replaceChildren(el('div', { class: 'about-grid' }, [text, side]));
  section.hidden = false;
  return true;
}
