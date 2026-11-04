// Graf zależności: węzły w kolumnach, połączenia krzywymi Electric Current.
import { el, svg } from '../lib/dom.js';
import { layoutGraph } from '../lib/graph-layout.js';

const OPTS = { colWidth: 204, rowHeight: 84, nodeW: 170, nodeH: 60, pad: 16 };

function wrap(label, max = 20) {
  if (label.length <= max) return [label];
  const mid = Math.floor(label.length / 2);
  let cut = label.lastIndexOf(' ', mid);
  if (cut < 4) cut = label.indexOf(' ', mid);
  if (cut < 0) return [label];
  return [label.slice(0, cut), label.slice(cut + 1)];
}

export function render(block) {
  let g;
  try { g = layoutGraph(block.nodes, block.edges, OPTS); } catch (e) {
    return el('p', { class: 'notice', text: 'This graph could not be displayed.' });
  }
  const s = svg('svg', { viewBox: `0 0 ${g.width} ${g.height}`, width: g.width, height: g.height, role: 'img', 'aria-hidden': 'true', focusable: 'false' });
  s.style.maxWidth = `${g.width}px`;
  s.style.minWidth = `${Math.min(g.width, 880)}px`;
  s.append(svg('defs', {}, [svg('linearGradient', { id: 'graph-grad', gradientUnits: 'userSpaceOnUse', x1: 0, y1: 0, x2: g.width, y2: 0 }, [
    svg('stop', { offset: '0', class: 'cv-stop-a' }), svg('stop', { offset: '1', class: 'cv-stop-b' }),
  ])]));
  for (const e of g.edges) s.append(svg('path', { d: e.d, class: 'graph-edge' }));
  for (const n of g.nodes) {
    const kind = n.kind ? ` graph-${n.kind}` : '';
    const grp = svg('g', { class: `graph-node${kind}` }, [svg('rect', { x: n.x, y: n.y, width: n.w, height: n.h, rx: 12 })]);
    const lines = wrap(n.label);
    lines.forEach((line, i) => {
      const t = svg('text', { x: n.x + n.w / 2, y: n.y + n.h / 2 + (i - (lines.length - 1) / 2) * 17 + 5, 'text-anchor': 'middle' });
      t.textContent = line;
      grp.append(t);
    });
    s.append(grp);
  }
  const labels = new Map(block.nodes.map((n) => [n.id, n.label]));
  const summary = block.edges.map((e) => `${labels.get(e.from)} to ${labels.get(e.to)}`).join('; ') || block.nodes.map((n) => n.label).join('; ');
  return el('div', { class: 'graph-scroll', attrs: { role: 'img', 'aria-label': `Dependencies: ${summary}`, tabindex: '0' } }, [s]);
}
