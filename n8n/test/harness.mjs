// Uruchamia kod węzła Code z n8n/code/*.js poza n8n, z atrapami $ i $input.
// nodes: { 'Nazwa węzła': json | [json, ...] } dla $('Nazwa').first().json i .all(); input: lista json-ów dla $input.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const codeDir = join(dirname(fileURLToPath(import.meta.url)), '..', 'code');

export function runCode(file, { nodes = {}, input = [{}], env = {} } = {}) {
  const source = readFileSync(join(codeDir, `${file}.js`), 'utf8')
    .replace(/^\/\/@include (\w[\w-]*)\s*$/gm, (_, lib) => readFileSync(join(codeDir, 'lib', `${lib}.js`), 'utf8'))
    // build-prompt.js ma w szablonie znacznik podmieniany przez build.mjs
    .replace('__PROMPT_TEMPLATE__', JSON.stringify((file === 'triage-prompt' ? '{{FAQ}}|{{SUBJECT}}|{{MESSAGE}}' : '{{PRODUCTS}}|{{MATERIALS}}|{{MESSAGE}}|{{WEEK}}|{{MONTH}}|{{NO}}')))
    .replace('__FAQ__', JSON.stringify('FAQ-TEKST'));
  const wrap = (arr) => ({ first: () => ({ json: arr[0] }), all: () => arr.map((json) => ({ json })) });
  const $ = (name) => {
    if (!(name in nodes)) throw new Error(`Brak węzła ${name} w atrapie`);
    return wrap(Array.isArray(nodes[name]) ? nodes[name] : [nodes[name]]);
  };
  $.input = wrap(input);
  return new Function('$', '$input', '$env', source)($, $.input, env).map((x) => x.json);
}
