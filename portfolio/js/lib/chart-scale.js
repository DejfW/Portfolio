// Skalowanie słupków poziomych. Czysta logika, bez DOM.
export function scaleBars(bars, { width, barHeight, gap, labelWidth }) {
  const avail = Math.max(0, width - labelWidth);
  const max = bars.reduce((m, b) => Math.max(m, b.value), 0);
  const out = bars.map((b, i) => ({
    label: b.label, value: b.value, y: i * (barHeight + gap), h: barHeight,
    w: max > 0 ? (b.value / max) * avail : 0,
  }));
  const height = bars.length ? bars.length * barHeight + (bars.length - 1) * gap : 0;
  return { width, height, bars: out };
}
