// Mały helper do budowania DOM. Tekst zawsze przez textContent / createTextNode.
export function el(tag, props = {}, children = []) {
  const node = document.createElement(tag);
  if (props.class) node.className = props.class;
  if (props.text !== undefined) node.textContent = props.text;
  for (const [k, v] of Object.entries(props.attrs || {})) node.setAttribute(k, v);
  for (const c of children) node.append(c);
  return node;
}

const SVG_NS = 'http://www.w3.org/2000/svg';
export function svg(tag, attrs = {}, children = []) {
  const node = document.createElementNS(SVG_NS, tag);
  for (const [k, v] of Object.entries(attrs)) node.setAttribute(k, String(v));
  for (const c of children) node.append(c);
  return node;
}
