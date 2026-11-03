#!/usr/bin/env node
// Waliduje portfolio: manifest, każdy projekt i site.json.
// Użycie: node scripts/validate-portfolio.mjs [--root <portfolio/projects>]
import { readFileSync, existsSync, readdirSync, statSync } from 'node:fs';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { validateManifest, validateProject, validateSite, isSlug } from '../portfolio/js/lib/schema.js';

const here = dirname(fileURLToPath(import.meta.url));
const argRoot = process.argv.indexOf('--root');
const projectsDir = resolve(argRoot > -1 ? process.argv[argRoot + 1] : join(here, '..', 'portfolio', 'projects'));
const siteDir = dirname(projectsDir);

const errors = [];
const warnings = [];

function readJson(file, label) {
  try { return JSON.parse(readFileSync(file, 'utf8')); } catch (e) {
    errors.push(`${label}: cannot read (${e.message})`);
    return null;
  }
}

const manifest = readJson(join(projectsDir, 'index.json'), 'projects/index.json');
let slugs = [];
if (manifest) {
  validateManifest(manifest).forEach((e) => errors.push(`projects/index.json: ${e}`));
  slugs = Array.isArray(manifest.projects) ? manifest.projects.filter(isSlug) : [];
}

for (const slug of slugs) {
  const dir = join(projectsDir, slug);
  const file = join(dir, 'project.json');
  if (!existsSync(file)) { errors.push(`${slug}: project.json not found (listed in manifest)`); continue; }
  const project = readJson(file, `${slug}/project.json`);
  if (!project) continue;
  validateProject(project, { slug, fileExists: (rel) => existsSync(join(dir, rel)) })
    .forEach((e) => errors.push(`${slug}: ${e}`));
  (project.sections || []).forEach((b, i) => {
    if (b && b.type === 'gallery' && Array.isArray(b.items) && b.items.length === 0) {
      warnings.push(`${slug}: sections[${i}] gallery is empty (placeholder shown on the page)`);
    }
  });
}

if (existsSync(projectsDir)) {
  for (const name of readdirSync(projectsDir)) {
    if (name.startsWith('_') || name.startsWith('.')) continue;
    if (statSync(join(projectsDir, name)).isDirectory() && !slugs.includes(name)) {
      warnings.push(`folder "${name}" is not listed in projects/index.json`);
    }
  }
}

const siteFile = join(siteDir, 'site.json');
if (existsSync(siteFile)) {
  const site = readJson(siteFile, 'site.json');
  if (site) validateSite(site, { fileExists: (rel) => existsSync(join(siteDir, rel)) }).forEach((e) => errors.push(`site.json: ${e}`));
}

warnings.forEach((w) => console.log(`WARN ${w}`));
if (errors.length) {
  errors.forEach((e) => console.error(`ERROR ${e}`));
  process.exit(1);
}
console.log(`OK: ${slugs.length} projects`);
