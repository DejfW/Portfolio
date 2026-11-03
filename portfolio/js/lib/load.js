// Ładowanie danych portfolio. Bez DOM: fetchJson jest wstrzykiwany, więc da się to testować w Node.
import { validateManifest, validateProject, isSlug } from './schema.js';

export function parseSlug(search) {
  const p = new URLSearchParams(search || '').get('p');
  return isSlug(p) ? p : null;
}

export async function loadProject(fetchJson, slug) {
  if (!isSlug(slug)) return { project: null, errors: [`invalid slug`] };
  try {
    const project = await fetchJson(`projects/${slug}/project.json`);
    const errs = validateProject(project, { slug, fileExists: () => true });
    if (errs.length) return { project: null, errors: [`${slug}: invalid project (${errs.join('; ')})`] };
    return { project, errors: [] };
  } catch (e) {
    return { project: null, errors: [`${slug}: ${e.message}`] };
  }
}

export async function loadProjects(fetchJson) {
  let manifest;
  try { manifest = await fetchJson('projects/index.json'); } catch (e) {
    return { projects: [], errors: [`projects/index.json: ${e.message}`] };
  }
  const manifestErrors = validateManifest(manifest);
  if (manifestErrors.length) return { projects: [], errors: manifestErrors.map((e) => `projects/index.json: ${e}`) };
  const results = await Promise.all(manifest.projects.map((slug) => loadProject(fetchJson, slug)));
  return {
    projects: results.filter((r) => r.project).map((r) => r.project),
    errors: results.flatMap((r) => r.errors),
  };
}

export async function fetchJson(url) {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`HTTP ${res.status} for ${url}`);
  return res.json();
}
