// Graf zależności w stylu mapy całego systemu: węzły z kolorową ramką wg rodzaju, strzałki z grotami,
// opcjonalne logotypy narzędzi i legenda. Układ liczy layoutGraph, etykiety zawija wrapLabel.
import { el, svg } from '../lib/dom.js';
import { layoutGraph } from '../lib/graph-layout.js';
import { wrapLabel } from '../lib/label-wrap.js';
import { legendFor } from '../lib/graph-legend.js';
import { ICONS } from '../lib/icons.js';

let graphSeq = 0;
const OPTS = { colWidth: 204, rowHeight: 84, nodeW: 170, nodeH: 60, pad: 16 };
const LINE_H = 17;
const ICON_SIZE = 22;

function drawNode(n, hasIcon) {
  const kind = n.kind ? ` graph-${n.kind}` : '';
  const grp = svg('g', { class: `graph-node${kind}` }, [svg('rect', { x: n.x, y: n.y, width: n.w, height: n.h, rx: 12 })]);
  const icon = n.icon && ICONS[n.icon] ? n.icon : null;
  const lines = wrapLabel(n.label, icon ? 15 : 20, 3);
  const textX = icon ? n.x + 14 + ICON_SIZE + 10 : n.x + n.w / 2;
  if (icon) {
    const g = svg('g', { class: 'graph-icon', transform: `translate(${n.x + 14} ${n.y + n.h / 2 - ICON_SIZE / 2}) scale(${ICON_SIZE / 24})` }, [svg('path', { d: ICONS[icon] })]);
    grp.append(g);
  }
  lines.forEach((line, i) => {
    const t = svg('text', { x: textX, y: n.y + n.h / 2 + (i - (lines.length - 1) / 2) * LINE_H + 5, 'text-anchor': icon ? 'start' : 'middle' });
    t.textContent = line;
    grp.append(t);
  });
  return grp;
}

export function render(block) {
  let g;
  try { g = layoutGraph(block.nodes, block.edges, OPTS); } catch (e) {
    return el('p', { class: 'notice', text: 'This graph could not be displayed.' });
  }
  const mid = `graph-arrow-${++graphSeq}`;
  const s = svg('svg', { viewBox: `0 0 ${g.width} ${g.height}`, width: g.width, height: g.height, 'aria-hidden': 'true', focusable: 'false' });
  s.style.maxWidth = `${g.width}px`;
  s.style.minWidth = `${Math.min(g.width, 880)}px`;
  s.append(svg('defs', {}, [svg('marker', { id: mid, viewBox: '0 0 10 10', refX: 8, refY: 5, markerWidth: 8, markerHeight: 8, orient: 'auto-start-reverse' }, [svg('path', { d: 'M0 0L10 5L0 10z', class: 'graph-arrow' })])]));
  for (const e of g.edges) s.append(svg('path', { d: e.d, class: 'graph-edge', 'marker-end': `url(#${mid})` }));
  const byId = new Map(block.nodes.map((n) => [n.id, n]));
  for (const n of g.nodes) s.append(drawNode({ ...n, icon: byId.get(n.id).icon }));

  const labels = new Map(block.nodes.map((n) => [n.id, n.label]));
  const summary = block.edges.map((e) => `${labels.get(e.from)} to ${labels.get(e.to)}`).join('; ') || block.nodes.map((n) => n.label).join('; ');
  const scroll = el('div', { class: 'graph-scroll', attrs: { role: 'img', 'aria-label': `Dependencies: ${summary}`, tabindex: '0' } }, [s]);

  const legend = legendFor(block.nodes);
  if (!legend.length) return el('div', { class: 'graph' }, [scroll]);
  const items = legend.map((l) => el('span', { class: 'graph-legend-item' }, [el('span', { class: `swatch swatch-${l.kind}` }), l.label]));
  return el('div', { class: 'graph' }, [scroll, el('div', { class: 'graph-legend t-caption' }, items)]);
}
