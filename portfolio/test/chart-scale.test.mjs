import { test } from 'node:test';
import assert from 'node:assert/strict';
import { scaleBars } from '../js/lib/chart-scale.js';

const opts = { width: 400, barHeight: 20, gap: 10, labelWidth: 100 };

test('longest bar fills available width', () => {
  const r = scaleBars([{ label: 'a', value: 10 }, { label: 'b', value: 5 }], opts);
  assert.equal(r.bars[0].w, 300);
  assert.equal(r.bars[1].w, 150);
});

test('all zeros yields zero widths without NaN', () => {
  const r = scaleBars([{ label: 'a', value: 0 }, { label: 'b', value: 0 }], opts);
  assert.deepEqual(r.bars.map((b) => b.w), [0, 0]);
  assert.ok(Number.isFinite(r.height));
});

test('single bar fills the width', () => {
  const r = scaleBars([{ label: 'a', value: 7 }], opts);
  assert.equal(r.bars[0].w, 300);
  assert.equal(r.height, 20);
});

test('empty list returns no bars and a finite height', () => {
  const r = scaleBars([], opts);
  assert.deepEqual(r.bars, []);
  assert.equal(r.height, 0);
});

test('bars are stacked with the gap', () => {
  const r = scaleBars([{ label: 'a', value: 1 }, { label: 'b', value: 1 }, { label: 'c', value: 1 }], opts);
  assert.deepEqual(r.bars.map((b) => b.y), [0, 30, 60]);
  assert.equal(r.height, 80);
});
