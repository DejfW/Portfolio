import { el } from './lib/dom.js';
import { fetchJson, loadProject, parseSlug } from './lib/load.js';
import { renderBlock } from './blocks/index.js';
import { linkButtons } from './about.js';

const STATUS_LABEL = { shipped: 'Shipped', 'in-progress': 'In progress', planned: 'Coming soon' };
const root = document.getElementById('project-root');

function message(title, text) {
  root.replaceChildren(el('section', { class: 'section' }, [el('div', { class: 'container stack' }, [
    el('h1', { class: 't-heading-lg', text: title }),
    el('p', { class: 't-subheading', text }),
    el('a', { class: 'btn btn-ghost plain', text: '← All projects', attrs: { href: 'index.html#projects' } }),
  ])]));
}

function header(project) {
  const meta = el('div', { class: 'project-meta' }, [el('span', { class: 'badge', text: STATUS_LABEL[project.status] })]);
  if (project.year) meta.append(el('span', { class: 't-caption', text: String(project.year) }));
  if (project.role) meta.append(el('span', { class: 't-caption', text: project.role }));
  const stack = el('div', { class: 'stack project-head' }, [
    el('a', { class: 'back-link t-caption', text: '← Projects', attrs: { href: 'index.html#projects' } }),
    meta,
    el('h1', { class: 't-display', text: project.title }),
    el('p', { class: 't-subheading project-lead', text: project.tagline }),
  ]);
  if (project.summary) stack.append(el('p', { class: 't-body project-summary', text: project.summary }));
  if (project.tags && project.tags.length) stack.append(el('div', { class: 'pill-list' }, project.tags.map((t) => el('span', { class: 'pill', text: t }))));
  if (project.links && project.links.length) stack.append(el('div', { class: 'btn-row' }, linkButtons({ links: project.links })));
  const parts = [el('div', { class: 'container' }, [stack])];
  if (project.stats && project.stats.length) {
    parts.push(el('div', { class: 'container stats-row' }, project.stats.map((s) => el('div', { class: 'card-glow' }, [
      el('div', { class: 'stat-value', text: s.value }), el('div', { class: 't-caption', text: s.label }),
    ]))));
  }
  return el('section', { class: 'section project-top' }, parts);
}

function sections(project, base) {
  return (project.sections || []).map((block, i) => {
    const inner = el('div', { class: 'container' });
    if (block.title) inner.append(el('h2', { class: 't-heading-lg section-title', text: block.title }));
    inner.append(renderBlock(block, { base }));
    return el('section', { class: i % 2 === 0 ? 'section block block-alt' : 'section block' }, [inner]);
  });
}

async function main() {
  const slug = parseSlug(location.search);
  if (!slug) return message('Project not found', 'That link does not point to a project.');
  const { project, errors } = await loadProject(fetchJson, slug);
  if (!project) { errors.forEach((e) => console.warn('portfolio:', e)); return message('Project not found', 'This project does not exist or could not be loaded.'); }
  fetchJson('site.json').then((s) => { document.title = `${project.title} — ${s.name}`; }).catch(() => {});
  document.title = project.title;
  const desc = document.querySelector('meta[name="description"]');
  if (desc) desc.setAttribute('content', project.tagline);
  if (project.status === 'planned') return message(project.title, 'This project is coming soon.');
  root.replaceChildren(header(project), ...sections(project, `projects/${slug}/`));
}

main();
