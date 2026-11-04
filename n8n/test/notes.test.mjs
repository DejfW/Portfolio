// Notatki (sticky notes) na płótnie n8n: grupują węzły i opisują je jednym zdaniem. Są czysto wizualne.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const load = (f) => JSON.parse(readFileSync(new URL(`../workflows/${f}`, import.meta.url), 'utf8'));
const EXPECTED = { '01-order-intake.json': 4, '03-team-tasks.json': 3, '04-stock-prices.json': 3 };
const isNote = (n) => n.type === 'n8n-nodes-base.stickyNote';
const box = (n) => ({ x1: n.position[0], y1: n.position[1], x2: n.position[0] + n.parameters.width, y2: n.position[1] + n.parameters.height });
const overlap = (a, b) => a.x1 < b.x2 && b.x1 < a.x2 && a.y1 < b.y2 && b.y1 < a.y2;

test('workflowy 01, 03 i 04 mają notatki grupujące węzły', () => {
  for (const [f, count] of Object.entries(EXPECTED)) {
    assert.equal(load(f).nodes.filter(isNote).length, count, f);
  }
});

test('każda notatka ma nagłówek, treść, wymiary i kolor', () => {
  for (const f of Object.keys(EXPECTED)) {
    for (const n of load(f).nodes.filter(isNote)) {
      assert.match(n.parameters.content, /^## .+\n.{20,}/s, `${f}: ${n.name}`);
      assert.ok(n.parameters.width > 0 && n.parameters.height > 0, `${f}: ${n.name} wymiary`);
      assert.ok(Number.isInteger(n.parameters.color) && n.parameters.color >= 1 && n.parameters.color <= 7, `${f}: ${n.name} kolor`);
    }
  }
});

test('notatki nie biorą udziału w połączeniach', () => {
  for (const f of Object.keys(EXPECTED)) {
    const w = load(f);
    const names = new Set(w.nodes.filter(isNote).map((n) => n.name));
    for (const [from, c] of Object.entries(w.connections)) {
      assert.ok(!names.has(from), `${f}: ${from} jako źródło`);
      for (const out of c.main) for (const to of out) assert.ok(!names.has(to.node), `${f}: ${to.node} jako cel`);
    }
  }
});

test('notatki nie nakładają się na siebie i obejmują co najmniej dwa węzły', () => {
  for (const f of Object.keys(EXPECTED)) {
    const w = load(f);
    const notes = w.nodes.filter(isNote);
    for (let i = 0; i < notes.length; i++) {
      for (let j = i + 1; j < notes.length; j++) assert.ok(!overlap(box(notes[i]), box(notes[j])), `${f}: ${notes[i].name} nakłada się na ${notes[j].name}`);
      const b = box(notes[i]);
      const inside = w.nodes.filter((n) => !isNote(n) && n.position[0] >= b.x1 && n.position[0] + 100 <= b.x2 && n.position[1] >= b.y1 && n.position[1] + 100 <= b.y2);
      assert.ok(inside.length >= 2, `${f}: ${notes[i].name} obejmuje ${inside.length} węzłów`);
    }
  }
});

test('workflowy bez notatek zostają bez zmian (08 i pozostałe)', () => {
  for (const f of ['00-llm.json', '02-intake-sweeper.json', '05-deliver.json', '08-purchase-orders.json']) {
    assert.equal(load(f).nodes.filter(isNote).length, 0, f);
  }
});
