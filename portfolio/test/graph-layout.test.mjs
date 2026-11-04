import { test } from 'node:test';
import assert from 'node:assert/strict';
import { layoutGraph } from '../js/lib/graph-layout.js';

const o = { colWidth: 200, rowHeight: 80, nodeW: 120, nodeH: 50, pad: 10 };
const N = (id, layer) => ({ id, label: id, layer });
const nums = (d) => d.match(/-?\d+(\.\d+)?/g).map(Number);

test('places nodes in columns by layer', () => {
  const r = layoutGraph([N('a', 0), N('b', 0), N('c', 1)], [], o);
  const x = Object.fromEntries(r.nodes.map((n) => [n.id, n.x]));
  assert.equal(x.a, 10);
  assert.equal(x.b, 10);
  assert.equal(x.c, 210);
  assert.equal(r.width, 10 + 200 + 120 + 10);
});

test('edge starts at source right edge and ends at target left edge', () => {
  const r = layoutGraph([N('a', 0), N('b', 1)], [{ from: 'a', to: 'b' }], o);
  const [x1, y1, , , , , x2, y2] = nums(r.edges[0].d);
  const a = r.nodes.find((n) => n.id === 'a'), b = r.nodes.find((n) => n.id === 'b');
  assert.equal(x1, a.x + a.w);
  assert.equal(y1, a.y + a.h / 2);
  assert.equal(x2, b.x);
  assert.equal(y2, b.y + b.h / 2);
});

test('orphan node without edges still gets a position', () => {
  const r = layoutGraph([N('a', 0), N('lonely', 2)], [], o);
  const n = r.nodes.find((x) => x.id === 'lonely');
  assert.ok(Number.isFinite(n.x) && Number.isFinite(n.y));
  assert.equal(r.edges.length, 0);
});

test('unknown edge endpoint throws', () => {
  assert.throws(() => layoutGraph([N('a', 0)], [{ from: 'a', to: 'x' }], o), /unknown node: x/);
  assert.throws(() => layoutGraph([N('a', 0)], [{ from: 'y', to: 'a' }], o), /unknown node: y/);
});

test('tallest column defines height and shorter columns are vertically centered', () => {
  const r = layoutGraph([N('a', 0), N('b', 0), N('c', 0), N('d', 1)], [], o);
  assert.equal(r.height, 10 + 2 * 80 + 50 + 10);
  const ys = Object.fromEntries(r.nodes.map((n) => [n.id, n.y]));
  assert.equal(ys.a, 10);
  assert.equal(ys.c, 170);
  assert.equal(ys.d, 10 + 80); // środek między 10 a 170
});

test('empty graph returns finite size', () => {
  const r = layoutGraph([], [], o);
  assert.ok(Number.isFinite(r.width) && Number.isFinite(r.height));
});
