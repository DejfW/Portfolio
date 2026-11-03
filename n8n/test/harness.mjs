// Uruchamia kod węzła Code z n8n/code/*.js poza n8n, z atrapami $ i $input.
// nodes: { 'Nazwa węzła': json } dla $('Nazwa').first().json; input: lista json-ów dla $input.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const codeDir = join(dirname(fileURLToPath(import.meta.url)), '..', 'code');

export function runCode(file, { nodes = {}, input = [{}] } = {}) {
  const source = readFileSync(join(codeDir, `${file}.js`), 'utf8')
    .replace(/^\/\/@include (\w[\w-]*)\s*$/gm, (_, lib) => readFileSync(join(codeDir, 'lib', `${lib}.js`), 'utf8'))
    // build-prompt.js ma w szablonie znacznik podmieniany przez build.mjs
    .replace('__PROMPT_TEMPLATE__', JSON.stringify('{{PRODUCTS}}|{{MATERIALS}}|{{MESSAGE}}'));
  const wrap = (arr) => ({ first: () => ({ json: arr[0] }), all: () => arr.map((json) => ({ json })) });
  const $ = (name) => {
    if (!(name in nodes)) throw new Error(`Brak węzła ${name} w atrapie`);
    return wrap([nodes[name]]);
  };
  $.input = wrap(input);
  return new Function('$', '$input', source)($, $.input).map((x) => x.json);
}
