// Układ kolumnowy grafu: kolumna = layer, węzły w kolejności wejściowej, kolumny wyśrodkowane pionowo.
export function layoutGraph(nodes, edges, { colWidth, rowHeight, nodeW, nodeH, pad }) {
  const columns = new Map();
  for (const n of nodes) {
    if (!columns.has(n.layer)) columns.set(n.layer, []);
    columns.get(n.layer).push(n);
  }
  const maxLayer = nodes.reduce((m, n) => Math.max(m, n.layer), 0);
  const maxRows = [...columns.values()].reduce((m, c) => Math.max(m, c.length), 0);
  const placed = [];
  for (const col of columns.values()) {
    const offset = ((maxRows - col.length) * rowHeight) / 2;
    col.forEach((n, k) => placed.push({
      id: n.id, label: n.label, kind: n.kind,
      x: pad + n.layer * colWidth, y: pad + offset + k * rowHeight, w: nodeW, h: nodeH,
    }));
  }
  const byId = new Map(placed.map((n) => [n.id, n]));
  const laidEdges = edges.map(({ from, to }) => {
    const a = byId.get(from), b = byId.get(to);
    if (!a) throw new Error(`unknown node: ${from}`);
    if (!b) throw new Error(`unknown node: ${to}`);
    const x1 = a.x + a.w, y1 = a.y + a.h / 2, x2 = b.x, y2 = b.y + b.h / 2, mx = (x1 + x2) / 2;
    return { from, to, d: `M ${x1} ${y1} C ${mx} ${y1} ${mx} ${y2} ${x2} ${y2}` };
  });
  return {
    width: pad * 2 + maxLayer * colWidth + nodeW,
    height: pad * 2 + Math.max(0, maxRows - 1) * rowHeight + (maxRows ? nodeH : 0),
    nodes: placed, edges: laidEdges,
  };
}
