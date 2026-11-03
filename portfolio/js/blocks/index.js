// Rejestr rendererów bloków. Tytuł sekcji (block.title) renderuje opakowanie w project.js, nie renderer.
import { el } from '../lib/dom.js';
import { render as prose } from './prose.js';
import { render as list } from './list.js';
import { render as table } from './table.js';

export const RENDERERS = { prose, list, table };

export function renderBlock(block, ctx) {
  const fn = RENDERERS[block.type];
  if (!fn) return el('p', { class: 'notice', text: `Unsupported block: ${block.type}` });
  try {
    return fn(block, ctx);
  } catch (e) {
    console.warn('portfolio: block failed', block.type, e);
    return el('p', { class: 'notice', text: `This ${block.type} block could not be displayed.` });
  }
}
