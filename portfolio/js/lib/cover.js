// Okładka karty projektu: obraz z `cover` albo dekoracyjne SVG z węzłami.
import { el, svg } from './dom.js';

export function coverFor(project, base) {
  const wrap = el('div', { class: 'project-cover' });
  if (project.cover) {
    wrap.append(el('img', { attrs: { src: `${base}${project.cover}`, alt: '', loading: 'lazy', decoding: 'async' } }));
    return wrap;
  }
  const s = svg('svg', { viewBox: '0 0 400 240', role: 'presentation', focusable: 'false' });
  const pts = [[30, 40], [30, 150], [160, 95], [290, 40], [290, 150]];
  const edges = [[0, 2], [1, 2], [2, 3], [2, 4]];
  for (const [a, b] of edges) {
    const [x1, y1] = [pts[a][0] + 80, pts[a][1] + 25], [x2, y2] = [pts[b][0], pts[b][1] + 25], mx = (x1 + x2) / 2;
    s.append(svg('path', { d: `M ${x1} ${y1} C ${mx} ${y1}, ${mx} ${y2}, ${x2} ${y2}`, class: 'cv-edge' }));
  }
  for (const [x, y] of pts) s.append(svg('rect', { x, y, width: 80, height: 50, rx: 10, class: 'cv-node' }), svg('circle', { cx: x + 20, cy: y + 25, r: 6, class: 'cv-dot cv-dot-cool' }));
  wrap.append(s);
  return wrap;
}
