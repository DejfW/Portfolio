// Dekoracyjny "canvas" workflow w hero: węzły połączone liniami Electric Current.
import { svg } from './lib/dom.js';

const NODES = [
  { id: 'a', x: 40, y: 60, hot: false }, { id: 'b', x: 40, y: 250, hot: false }, { id: 'c', x: 40, y: 430, hot: false },
  { id: 'd', x: 270, y: 150, hot: true }, { id: 'e', x: 270, y: 350, hot: false },
  { id: 'f', x: 500, y: 250, hot: true },
];
const EDGES = [['a', 'd'], ['b', 'd'], ['b', 'e'], ['c', 'e'], ['d', 'f'], ['e', 'f']];
const W = 150, H = 76;

export function renderHero(container) {
  const root = svg('svg', { viewBox: '0 0 720 540', role: 'presentation', focusable: 'false' });
  const defs = svg('defs', {}, [svg('linearGradient', { id: 'cv-grad', x1: '0', y1: '0', x2: '1', y2: '1' }, [
    svg('stop', { offset: '0', class: 'cv-stop-a' }), svg('stop', { offset: '1', class: 'cv-stop-b' }),
  ])]);
  root.append(defs);
  const byId = Object.fromEntries(NODES.map((n) => [n.id, n]));
  for (const [from, to] of EDGES) {
    const a = byId[from], b = byId[to];
    const x1 = a.x + W, y1 = a.y + H / 2, x2 = b.x, y2 = b.y + H / 2, mx = (x1 + x2) / 2;
    root.append(svg('path', { d: `M ${x1} ${y1} C ${mx} ${y1}, ${mx} ${y2}, ${x2} ${y2}`, class: 'cv-edge cv-flow' }));
  }
  for (const n of NODES) {
    root.append(
      svg('rect', { x: n.x, y: n.y, width: W, height: H, rx: 12, class: n.hot ? 'cv-node cv-node-hot' : 'cv-node' }),
      svg('circle', { cx: n.x + 28, cy: n.y + H / 2, r: 9, class: n.hot ? 'cv-dot' : 'cv-dot cv-dot-cool' }),
      svg('rect', { x: n.x + 52, y: n.y + 26, width: 70, height: 8, rx: 4, class: 'cv-bar' }),
      svg('rect', { x: n.x + 52, y: n.y + 44, width: 46, height: 6, rx: 3, class: 'cv-bar' }),
    );
  }
  container.replaceChildren(root);
}
