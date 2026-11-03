#!/usr/bin/env node
// Generuje n8n/workflows/*.json z kodu w n8n/code/*.js i promptów w n8n/prompts/*.md.
// Dzięki temu logika węzłów Code to zwykłe pliki JS (diffy, recenzje), a JSON jest wynikiem builda.
// Użycie: node n8n/build.mjs
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)));
const code = (name) => readFileSync(join(root, 'code', `${name}.js`), 'utf8');
const prompt = (name) => readFileSync(join(root, 'prompts', `${name}.md`), 'utf8');

const LLM_WORKFLOW_ID = 'llm0000000000001';
const INTAKE_WORKFLOW_ID = 'intake000000001';

// --- pomocnicze konstruktory węzłów -----------------------------------------------------------

let seq = 0;
const node = (name, type, typeVersion, position, parameters = {}, extra = {}) => ({
  id: `n${String(++seq).padStart(3, '0')}-${name.toLowerCase().replace(/[^a-z0-9]+/g, '-')}`,
  name, type, typeVersion, position, parameters, ...extra,
});

const codeNode = (name, position, source) =>
  node(name, 'n8n-nodes-base.code', 2, position, { mode: 'runOnceForAllItems', language: 'javaScript', jsCode: source });

const cfgRef = (field) => `$('Config').first().json.${field}`;

// Wywołanie funkcji SQL przez PostgREST. `body` to wyrażenie JS zwracające obiekt z argumentami.
const rpc = (name, position, fn, body, extra = {}, options = {}) =>
  node(name, 'n8n-nodes-base.httpRequest', 4.2, position, {
    method: 'POST',
    url: `={{ ${cfgRef('supabaseUrl')} }}/rest/v1/rpc/${fn}`,
    sendHeaders: true,
    headerParameters: {
      parameters: [
        { name: 'apikey', value: `={{ ${cfgRef('serviceKey')} }}` },
        { name: 'Authorization', value: `=Bearer {{ ${cfgRef('serviceKey')} }}` },
        { name: 'Content-Type', value: 'application/json' },
      ],
    },
    sendBody: true,
    contentType: 'json',
    specifyBody: 'json',
    jsonBody: `={{ JSON.stringify(${body}) }}`,
    options,
  }, extra);

const boolIf = (name, position, expr, expected = true) =>
  node(name, 'n8n-nodes-base.if', 2.2, position, {
    conditions: {
      options: { caseSensitive: true, leftValue: '', typeValidation: 'strict', version: 2 },
      conditions: [{
        id: `cond-${name}`.toLowerCase().replace(/[^a-z0-9]+/g, '-'),
        leftValue: `={{ ${expr} }}`,
        rightValue: '',
        operator: { type: 'boolean', operation: expected ? 'true' : 'false', singleValue: true },
      }],
      combinator: 'and',
    },
    options: {},
  });

// connections: [[od, do, wyjście?]] gdzie wyjście 0 = true/domyślne
function connect(links) {
  const c = {};
  for (const [from, to, output = 0] of links) {
    c[from] ??= { main: [] };
    c[from].main[output] ??= [];
    c[from].main[output].push({ node: to, type: 'main', index: 0 });
  }
  for (const v of Object.values(c)) for (let i = 0; i < v.main.length; i++) v.main[i] ??= [];
  return c;
}

const workflow = (id, name, nodes, links) => ({
  id, name, nodes, connections: connect(links), active: false, pinData: {},
  settings: { executionOrder: 'v1' }, versionId: `${id}-v1`,
});

// --- 00-llm: wspólny sub-workflow wywołujący model -------------------------------------------

function buildLlm() {
  const nodes = [
    node('Trigger', 'n8n-nodes-base.executeWorkflowTrigger', 1.1, [0, 0], { inputSource: 'passthrough' }),
    codeNode('Prepare', [240, 0], code('llm-prepare')),
    node('Run llm.sh', 'n8n-nodes-base.executeCommand', 1, [480, 0], {
      command: `=printf %s '{{ $json.b64 }}' | base64 -d | LLM_MOCK='{{ $json.mock }}' "{{ $json.projectDir }}/scripts/llm.sh"`,
    }, { onError: 'continueRegularOutput' }),
    codeNode('Result', [720, 0], code('llm-result')),
  ];
  return workflow(LLM_WORKFLOW_ID, '00 LLM', nodes, [
    ['Trigger', 'Prepare'], ['Prepare', 'Run llm.sh'], ['Run llm.sh', 'Result'],
  ]);
}

// --- 01-order-intake -------------------------------------------------------------------------

function buildIntake() {
  const env = (name, fallback) => (fallback === undefined ? `={{ $env.${name} }}` : `={{ $env.${name} || '${fallback}' }}`);
  const set = (name, value, type = 'string') => ({ id: `cfg-${name}`, name, value, type });

  const promptTemplate = JSON.stringify(prompt('parse-order'));

  const nodes = [
    node('Webhook', 'n8n-nodes-base.webhook', 2.1, [0, 0], {
      httpMethod: 'POST', path: 'order', responseMode: 'responseNode', options: {},
    }, { webhookId: 'order-intake-0001' }),
    node('Config', 'n8n-nodes-base.set', 3.4, [220, 0], {
      mode: 'manual',
      assignments: {
        assignments: [
          set('supabaseUrl', env('SUPABASE_URL')),
          set('serviceKey', env('SUPABASE_SERVICE_KEY')),
          set('projectDir', env('PROJECT_DIR')),
          set('allowMock', env('ALLOW_LLM_MOCK', '0')),
          set('ownerEmail', env('OWNER_EMAIL', 'owner@example.com')),
          set('publicUrl', env('PUBLIC_URL', 'http://localhost:5678')),
        ],
      },
      includeOtherFields: true,
      options: {},
    }),
    codeNode('Normalize', [440, 0], code('normalize')),
    boolIf('Valid input?', [660, 0], '$json.valid'),
    node('Accepted', 'n8n-nodes-base.respondToWebhook', 1.1, [880, -100], {
      respondWith: 'json',
      responseBody: `={{ { external_id: $json.external_id, status: 'processing' } }}`,
      options: { responseCode: 200 },
    }),
    node('Rejected', 'n8n-nodes-base.respondToWebhook', 1.1, [880, 120], {
      respondWith: 'json',
      responseBody: `={{ { error: 'INVALID_INPUT', fields: $json.errors } }}`,
      options: { responseCode: 400 },
    }),
    rpc('Already seen?', [1100, -100], 'intake_status', `{ p_external_id: $('Normalize').first().json.external_id }`),
    boolIf('New order?', [1320, -100], '$json.exists', false),
    node('Catalog', 'n8n-nodes-base.httpRequest', 4.2, [1540, -100], {
      method: 'POST',
      url: `={{ ${cfgRef('supabaseUrl')} }}/rest/v1/rpc/catalog_for_llm`,
      sendHeaders: true,
      headerParameters: {
        parameters: [
          { name: 'apikey', value: `={{ ${cfgRef('serviceKey')} }}` },
          { name: 'Authorization', value: `=Bearer {{ ${cfgRef('serviceKey')} }}` },
          { name: 'Content-Type', value: 'application/json' },
        ],
      },
      sendBody: true, contentType: 'json', specifyBody: 'json', jsonBody: '={}', options: {},
    }),
    codeNode('Build prompt', [1760, -100], code('build-prompt').replace('__PROMPT_TEMPLATE__', promptTemplate)),
    node('Ask LLM', 'n8n-nodes-base.executeWorkflow', 1.2, [1980, -100], {
      source: 'database',
      workflowId: { __rl: true, value: LLM_WORKFLOW_ID, mode: 'id' },
      options: { waitForSubWorkflow: true },
    }),
    codeNode('Validate', [2200, -100], code('validate-llm')),
    rpc('Intake order', [2420, -100], 'intake_order', `{ p: $json.payload }`),
    codeNode('Compose emails', [2640, -100], code('compose-emails')),
    rpc('Queue email', [2860, -100], 'enqueue_email',
      `{ p_order_id: $json.order_id, p_kind: $json.kind, p_to: $json.to, p_subject: $json.subject, p_body: $json.body }`,
      {}, { response: { response: { responseFormat: 'text' } } }), // funkcja zwraca sam uuid, wynik jest nieużywany
  ];

  return workflow(INTAKE_WORKFLOW_ID, '01 Order intake', nodes, [
    ['Webhook', 'Config'], ['Config', 'Normalize'], ['Normalize', 'Valid input?'],
    ['Valid input?', 'Accepted', 0], ['Valid input?', 'Rejected', 1],
    ['Accepted', 'Already seen?'], ['Already seen?', 'New order?'], ['New order?', 'Catalog', 0],
    ['Catalog', 'Build prompt'], ['Build prompt', 'Ask LLM'], ['Ask LLM', 'Validate'],
    ['Validate', 'Intake order'], ['Intake order', 'Compose emails'], ['Compose emails', 'Queue email'],
  ]);
}

// --- zapis -------------------------------------------------------------------------------------

const outDir = join(root, 'workflows');
mkdirSync(outDir, { recursive: true });
for (const [file, wf] of [['00-llm.json', buildLlm()], ['01-order-intake.json', buildIntake()]]) {
  writeFileSync(join(outDir, file), JSON.stringify(wf, null, 2) + '\n');
  console.log(`zapisano n8n/workflows/${file} (${wf.nodes.length} węzłów)`);
}
