// Zawijanie etykiet węzłów grafu: zachłannie po słowach, maksymalnie maxLines linii.
// Gdy tekst się nie mieści, ostatnia linia kończy się wielokropkiem. Jedno słowo dłuższe niż limit zostaje w całości.
export function wrapLabel(label, maxChars, maxLines) {
  const words = String(label).trim().split(/\s+/).filter(Boolean);
  if (!words.length) return [''];
  const lines = [];
  let i = 0;
  while (i < words.length && lines.length < maxLines) {
    let line = words[i++];
    while (i < words.length && (line + ' ' + words[i]).length <= maxChars) line += ' ' + words[i++];
    lines.push(line);
  }
  if (i < words.length) {
    const rest = lines.pop() + ' ' + words.slice(i).join(' ');
    lines.push(rest.length > maxChars ? rest.slice(0, maxChars - 1) + '…' : rest);
  }
  return lines;
}
