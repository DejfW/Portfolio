import { el } from './lib/dom.js';
import { fetchJson, loadProjects } from './lib/load.js';
import { coverFor } from './lib/cover.js';
import { validateSite } from './lib/schema.js';
import { renderHero } from './hero.js';
import { renderAbout, linkButtons } from './about.js';

const STATUS_LABEL = { shipped: 'Shipped', 'in-progress': 'In progress', planned: 'Coming soon' };

function tagList(tags) {
  return el('div', { class: 'pill-list' }, (tags || []).map((t) => el('span', { class: 'pill', text: t })));
}

function statsRow(stats) {
  if (!stats || !stats.length) return null;
  return el('div', { class: 'project-stats' }, stats.slice(0, 3).map((s) => el('div', {}, [
    el('div', { class: 'stat-value', text: s.value }), el('div', { class: 't-caption', text: s.label }),
  ])));
}

function meta(project) {
  const m = el('div', { class: 'project-meta' }, [el('span', { class: 'badge', text: STATUS_LABEL[project.status] })]);
  if (project.year) m.append(el('span', { class: 't-caption', text: String(project.year) }));
  return m;
}

export function projectCard(project, featured) {
  const planned = project.status === 'planned';
  const base = `projects/${project.slug}/`;
  const cls = planned ? 'project project-planned card-glow' : featured ? 'project project-featured panel' : 'project card';
  const heading = el('h3', { class: featured ? 't-heading-lg' : 't-heading' });
  if (planned) heading.textContent = project.title;
  else heading.append(el('a', { class: 'plain', text: project.title, attrs: { href: `project.html?p=${project.slug}` } }));

  const body = el('div', { class: 'project-body' }, [meta(project), heading, el('p', { class: 't-subheading', text: project.tagline })]);
  const stats = planned ? null : statsRow(project.stats);
  if (stats) body.append(stats);
  if (project.tags && project.tags.length) body.append(tagList(project.tags));
  const card = el('article', { class: cls }, [body]);
  if (!planned) card.append(coverFor(project, base));
  if (!featured || planned) { card.classList.remove('project-featured'); }
  return card;
}

async function main() {
  const [site, { projects, errors }] = await Promise.all([
    fetchJson('site.json').catch((e) => { console.warn('site.json:', e.message); return null; }),
    loadProjects(fetchJson),
  ]);
  errors.forEach((e) => console.warn('portfolio:', e));

  const siteErrors = site ? validateSite(site, { fileExists: () => true }) : [];
  if (siteErrors.length) siteErrors.forEach((e) => console.warn('portfolio: site.json:', e));
  if (site && !siteErrors.length) {
    document.getElementById('brand').textContent = site.name;
    document.getElementById('hero-title').textContent = site.headline;
    document.title = `${site.name} — ${site.headline}`;
    const gh = linkButtons({ links: (site.links || []).filter((l) => /github\.com/i.test(l.url)) }, 'btn btn-frosted plain');
    document.getElementById('nav-extra').replaceChildren(...gh);
    document.getElementById('hero-extra').replaceChildren(...linkButtons({ links: (site.links || []).filter((l) => /github\.com/i.test(l.url)) }, 'btn btn-ghost plain'));
    document.getElementById('footer-links').replaceChildren(...linkButtons(site, 'plain t-caption'));
    renderAbout(site, document.getElementById('about'), document.getElementById('about-content'));
  }
  renderHero(document.getElementById('hero-canvas'));

  const list = document.getElementById('projects-list');
  if (!projects.length) { list.replaceChildren(el('p', { class: 'notice', text: 'No projects yet.' })); return; }
  list.replaceChildren(...projects.map((p, i) => projectCard(p, i === 0 && p.status !== 'planned')));
}

main();
