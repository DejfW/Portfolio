// Walidator danych portfolio. Bez importów Node: działa w przeglądarce i w CLI.

export const STATUSES = ['shipped', 'in-progress', 'planned'];
export const BLOCK_TYPES = ['prose', 'list', 'table', 'gallery', 'diagram', 'chart', 'graph'];
export const NODE_KINDS = ['channel', 'workflow', 'db', 'ai', 'output'];

const SLUG_RE = /^[a-z0-9]+(-[a-z0-9]+)*$/;
const IMAGE_EXTS = ['png', 'jpg', 'jpeg', 'webp', 'gif', 'svg'];
const VIDEO_EXTS = ['mp4', 'webm'];

const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const isStr = (v) => typeof v === 'string' && v.trim() !== '';
const extOf = (p) => (p.includes('.') ? p.split('.').pop().toLowerCase() : '');

export function isSlug(s) {
  return typeof s === 'string' && SLUG_RE.test(s);
}

export function isSafeRelPath(p) {
  if (typeof p !== 'string' || p === '') return false;
  if (p.startsWith('/') || p.includes('\\') || p.includes('\0')) return false;
  if (/^[a-z][a-z0-9+.-]*:/i.test(p)) return false;
  if (![...IMAGE_EXTS, ...VIDEO_EXTS, 'pdf'].includes(extOf(p))) return false;
  return !p.split('/').some((seg) => seg === '..' || seg === '' || seg === '.');
}

export function isSafeUrl(u, { allowMailto = false } = {}) {
  if (typeof u !== 'string') return false;
  if (/^https?:\/\/[^\s]+$/i.test(u)) return true;
  return allowMailto && /^mailto:[^\s]+$/i.test(u);
}

function checkMedia(path, value, ctx, errors, exts) {
  if (!isSafeRelPath(value)) { errors.push(`${path}: unsafe or invalid path`); return; }
  if (!exts.includes(extOf(value))) { errors.push(`${path}: extension must be one of ${exts.join(', ')}`); return; }
  if (!ctx.fileExists(value)) errors.push(`${path}: file not found`);
}

function checkLinks(path, links, errors, opts) {
  if (!Array.isArray(links)) { errors.push(`${path}: must be an array`); return; }
  links.forEach((l, i) => {
    if (!isObj(l) || !isStr(l.label)) { errors.push(`${path}[${i}].label: required`); return; }
    if (!isSafeUrl(l.url, opts)) errors.push(`${path}[${i}].url: must be a safe URL`);
  });
}

function requireStrings(path, arr, errors) {
  if (!Array.isArray(arr) || arr.some((s) => typeof s !== 'string')) errors.push(`${path}: must be an array of strings`);
}

const BLOCKS = {
  prose(b, p, ctx, errors) {
    if (!Array.isArray(b.paragraphs) || b.paragraphs.length === 0) errors.push(`${p}.paragraphs: required`);
    else requireStrings(`${p}.paragraphs`, b.paragraphs, errors);
  },
  list(b, p, ctx, errors) {
    if (!Array.isArray(b.items) || b.items.length === 0) { errors.push(`${p}.items: required`); return; }
    b.items.forEach((it, i) => {
      if (!isObj(it) || !isStr(it.title) || typeof it.text !== 'string') errors.push(`${p}.items[${i}]: needs title and text`);
    });
  },
  table(b, p, ctx, errors) {
    if (!Array.isArray(b.columns) || b.columns.length === 0) { errors.push(`${p}.columns: required`); return; }
    requireStrings(`${p}.columns`, b.columns, errors);
    if (!Array.isArray(b.rows)) { errors.push(`${p}.rows: required`); return; }
    b.rows.forEach((r, i) => {
      if (!Array.isArray(r) || r.length !== b.columns.length || r.some((c) => typeof c !== 'string')) {
        errors.push(`${p}.rows[${i}]: must have ${b.columns.length} string cells`);
      }
    });
  },
  gallery(b, p, ctx, errors) {
    if (b.layout !== undefined && b.layout !== 'wide') errors.push(`${p}.layout: must be "wide" or omitted`);
    if (!Array.isArray(b.items)) { errors.push(`${p}.items: required (may be empty)`); return; }
    b.items.forEach((it, i) => {
      const ip = `${p}.items[${i}]`;
      if (!isObj(it)) { errors.push(`${ip}: must be an object`); return; }
      if (it.type === 'image') {
        checkMedia(`${ip}.src`, it.src, ctx, errors, IMAGE_EXTS);
        if (!isStr(it.alt)) errors.push(`${ip}.alt: required for images`);
      } else if (it.type === 'video') {
        checkMedia(`${ip}.src`, it.src, ctx, errors, VIDEO_EXTS);
        if (it.poster !== undefined) checkMedia(`${ip}.poster`, it.poster, ctx, errors, IMAGE_EXTS);
      } else errors.push(`${ip}.type: must be "image" or "video"`);
    });
  },
  diagram(b, p, ctx, errors) {
    checkMedia(`${p}.src`, b.src, ctx, errors, IMAGE_EXTS);
    if (!isStr(b.alt)) errors.push(`${p}.alt: required`);
  },
  chart(b, p, ctx, errors) {
    if (!Array.isArray(b.bars) || b.bars.length === 0) { errors.push(`${p}.bars: required`); return; }
    b.bars.forEach((bar, i) => {
      if (!isObj(bar) || !isStr(bar.label)) errors.push(`${p}.bars[${i}].label: required`);
      if (!isObj(bar) || typeof bar.value !== 'number' || !Number.isFinite(bar.value) || bar.value < 0) {
        errors.push(`${p}.bars[${i}].value: must be a finite number >= 0`);
      }
    });
  },
  graph(b, p, ctx, errors) {
    if (!Array.isArray(b.nodes) || b.nodes.length === 0) { errors.push(`${p}.nodes: required`); return; }
    const layers = new Map();
    b.nodes.forEach((n, i) => {
      const np = `${p}.nodes[${i}]`;
      if (!isObj(n) || !isStr(n.id) || !isStr(n.label)) { errors.push(`${np}: needs id and label`); return; }
      if (layers.has(n.id)) errors.push(`${np}.id: duplicate "${n.id}"`);
      if (!Number.isInteger(n.layer) || n.layer < 0) errors.push(`${np}.layer: must be an integer >= 0`);
      else layers.set(n.id, n.layer);
      if (n.kind !== undefined && !NODE_KINDS.includes(n.kind)) errors.push(`${np}.kind: must be one of ${NODE_KINDS.join(', ')}`);
    });
    if (!Array.isArray(b.edges)) { errors.push(`${p}.edges: required (may be empty)`); return; }
    b.edges.forEach((e, i) => {
      const ep = `${p}.edges[${i}]`;
      if (!isObj(e) || !layers.has(e.from)) { errors.push(`${ep}.from: unknown node "${e && e.from}"`); return; }
      if (!layers.has(e.to)) { errors.push(`${ep}.to: unknown node "${e.to}"`); return; }
      if (layers.get(e.from) >= layers.get(e.to)) errors.push(`${ep}: edge must go to a later layer`);
    });
  },
};

export function validateProject(project, ctx) {
  const errors = [];
  if (!isObj(project)) return ['project: must be an object'];
  if (project.slug !== ctx.slug) errors.push(`slug: must equal folder name "${ctx.slug}"`);
  if (!isStr(project.title)) errors.push('title: required');
  if (!STATUSES.includes(project.status)) errors.push(`status: must be one of ${STATUSES.join(', ')}`);
  if (!isStr(project.tagline) || project.tagline.length > 140) errors.push('tagline: required, max 140 characters');
  if (project.year !== undefined && !Number.isInteger(project.year)) errors.push('year: must be an integer');
  if (project.role !== undefined && typeof project.role !== 'string') errors.push('role: must be a string');
  if (project.summary !== undefined && typeof project.summary !== 'string') errors.push('summary: must be a string');
  if (project.tags !== undefined) requireStrings('tags', project.tags, errors);
  if (project.cover !== undefined) checkMedia('cover', project.cover, ctx, errors, IMAGE_EXTS);
  if (project.links !== undefined) checkLinks('links', project.links, errors);
  if (project.stats !== undefined) {
    if (!Array.isArray(project.stats)) errors.push('stats: must be an array');
    else project.stats.forEach((s, i) => {
      if (!isObj(s) || !isStr(s.value) || !isStr(s.label)) errors.push(`stats[${i}]: needs string value and label`);
    });
  }
  const planned = project.status === 'planned';
  if (!planned && !isStr(project.summary)) errors.push('summary: required unless status is planned');
  if (project.sections === undefined) {
    if (!planned) errors.push('sections: required unless status is planned');
  } else if (!Array.isArray(project.sections) || (!planned && project.sections.length === 0)) {
    errors.push('sections: must be a non-empty array');
  } else {
    project.sections.forEach((b, i) => {
      const bp = `sections[${i}]`;
      if (!isObj(b)) { errors.push(`${bp}: must be an object`); return; }
      if (!BLOCK_TYPES.includes(b.type)) { errors.push(`${bp}.type: unknown block type "${b.type}"`); return; }
      if (b.title !== undefined && typeof b.title !== 'string') errors.push(`${bp}.title: must be a string`);
      BLOCKS[b.type](b, bp, ctx, errors);
    });
  }
  return errors;
}

export function validateManifest(manifest) {
  if (!isObj(manifest) || !Array.isArray(manifest.projects)) return ['projects: must be an array'];
  const errors = [];
  const seen = new Set();
  manifest.projects.forEach((s, i) => {
    if (!isSlug(s)) errors.push(`projects[${i}]: invalid slug`);
    else if (seen.has(s)) errors.push(`projects[${i}]: duplicate slug "${s}"`);
    seen.add(s);
  });
  return errors;
}

export function validateSite(site, ctx) {
  if (!isObj(site)) return ['site: must be an object'];
  const errors = [];
  if (!isStr(site.name)) errors.push('name: required');
  if (!isStr(site.headline)) errors.push('headline: required');
  if (site.about !== undefined) {
    if (!isObj(site.about) || !Array.isArray(site.about.paragraphs)) errors.push('about.paragraphs: required');
    else requireStrings('about.paragraphs', site.about.paragraphs, errors);
  }
  if (site.highlights !== undefined) {
    if (!Array.isArray(site.highlights)) errors.push('highlights: must be an array');
    else site.highlights.forEach((h, i) => {
      if (!isObj(h) || !isStr(h.title) || typeof h.text !== 'string') errors.push(`highlights[${i}]: needs title and text`);
    });
  }
  if (site.skills !== undefined) {
    if (!Array.isArray(site.skills)) errors.push('skills: must be an array');
    else site.skills.forEach((g, i) => {
      if (!isObj(g) || !isStr(g.group)) errors.push(`skills[${i}].group: required`);
      else requireStrings(`skills[${i}].items`, g.items, errors);
    });
  }
  checkLinks('links', site.links === undefined ? [] : site.links, errors, { allowMailto: true });
  if (site.cv !== undefined) {
    if (!isObj(site.cv) || !isStr(site.cv.label)) errors.push('cv.label: required');
    else checkMedia('cv.url', site.cv.url, ctx, errors, ['pdf']);
  }
  return errors;
}

// Przepuszcza tylko poprawne linki (http, https, mailto); reszta jest odrzucana po cichu.
export function safeLinks(links) {
  if (!Array.isArray(links)) return [];
  return links.filter((l) => isObj(l) && isStr(l.label) && isSafeUrl(l.url, { allowMailto: true }));
}
