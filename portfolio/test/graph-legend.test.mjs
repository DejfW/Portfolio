import { test } from 'node:test';
import assert from 'node:assert/strict';
import { legendFor, KIND_LABELS } from '../js/lib/graph-legend.js';
import { ICON_NAMES, ICONS } from '../js/lib/icons.js';

test('legend lists only the kinds present, in a fixed order', () => {
  const nodes = [{ kind: 'output' }, { kind: 'channel' }, { kind: 'channel' }, { kind: 'db' }, {}];
  assert.deepEqual(legendFor(nodes).map((l) => l.kind), ['channel', 'db', 'output']);
});

test('legend labels match the system map', () => {
  assert.deepEqual(KIND_LABELS, { channel: 'Input channel', workflow: 'n8n workflow', db: 'Database', ai: 'AI', output: 'Output' });
});

test('legend is empty when no node has a kind', () => {
  assert.deepEqual(legendFor([{}, {}]), []);
});

test('every icon name has an SVG path', () => {
  assert.deepEqual([...ICON_NAMES].sort(), ['gmail', 'n8n', 'postgresql', 'slack', 'supabase']);
  for (const n of ICON_NAMES) assert.match(ICONS[n], /^M[\d.\-]/, n);
});
