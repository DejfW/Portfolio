import { test } from 'node:test';
import assert from 'node:assert/strict';
import { wrapLabel } from '../js/lib/label-wrap.js';

test('short label stays on one line', () => {
  assert.deepEqual(wrapLabel('Slack', 20, 3), ['Slack']);
});

test('wraps greedily at word boundaries', () => {
  assert.deepEqual(wrapLabel('Supabase SQL functions', 16, 3), ['Supabase SQL', 'functions']);
});

test('uses at most maxLines and ends with an ellipsis when text is cut', () => {
  const out = wrapLabel('one two three four five six seven eight nine ten', 10, 2);
  assert.equal(out.length, 2);
  assert.ok(out[1].endsWith('…'), out[1]);
  assert.ok(out.every((l) => l.length <= 10), out.join('|'));
});

test('a single word longer than the limit is kept whole on its own line', () => {
  assert.deepEqual(wrapLabel('supplier_prices_with_a_very_long_name', 12, 3), ['supplier_prices_with_a_very_long_name']);
});

test('empty label gives one empty line', () => {
  assert.deepEqual(wrapLabel('', 10, 3), ['']);
});
