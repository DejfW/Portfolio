// Legenda grafu, taka jak na mapie całego systemu: tylko rodzaje węzłów, które faktycznie występują.
export const KIND_ORDER = ['channel', 'workflow', 'db', 'ai', 'output'];
export const KIND_LABELS = { channel: 'Input channel', workflow: 'n8n workflow', db: 'Database', ai: 'AI', output: 'Output' };

export function legendFor(nodes) {
  const present = new Set(nodes.map((n) => n.kind).filter(Boolean));
  return KIND_ORDER.filter((k) => present.has(k)).map((kind) => ({ kind, label: KIND_LABELS[kind] }));
}
