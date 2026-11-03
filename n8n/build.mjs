#!/usr/bin/env node
// Generuje n8n/workflows/*.json z kodu w n8n/code/*.js i promptów w n8n/prompts/*.md.
// Dzięki temu logika węzłów Code to zwykłe pliki JS (diffy, recenzje, testy w n8n/test),
// a JSON jest wynikiem builda.
// Użycie: node n8n/build.mjs
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)));
// Linia `//@include nazwa` jest zastępowana plikiem n8n/code/lib/nazwa.js (wspólne pomocniki węzłów Code).
const code = (name) => readFileSync(join(root, 'code', `${name}.js`), 'utf8')
  .replace(/^\/\/@include (\w[\w-]*)\s*$/gm, (_, lib) => readFileSync(join(root, 'code', 'lib', `${lib}.js`), 'utf8'));
const prompt = (name) => readFileSync(join(root, 'prompts', `${name}.md`), 'utf8');

const LLM_WORKFLOW_ID = 'llm0000000000001';
const INTAKE_WORKFLOW_ID = 'intake000000001';
const SWEEPER_WORKFLOW_ID = 'sweeper00000001';
const TEAM_WORKFLOW_ID = 'team00000000001';
const STOCK_WORKFLOW_ID = 'stock0000000001';
const DELIVER_WORKFLOW_ID = 'deliver00000001';
const SMTP_CREDENTIAL = { id: 'smtpgmail000001', name: 'Gmail SMTP' };

// --- pomocnicze konstruktory węzłów -----------------------------------------------------------

let seq = 0;
const node = (name, type, typeVersion, position, parameters = {}, extra = {}) => ({
  id: `n${String(++seq).padStart(3, '0')}-${name.toLowerCase().replace(/[^a-z0-9]+/g, '-')}`,
  name, type, typeVersion, position, parameters, ...extra,
});

const codeNode = (name, position, source) =>
  node(name, 'n8n-nodes-base.code', 2, position, { mode: 'runOnceForAllItems', language: 'javaScript', jsCode: source });

// Adres i klucz Supabase czytamy bezpośrednio ze środowiska w wyrażeniach HTTP. Dzięki temu klucz
// nie trafia do elementów danych, a więc nie jest zapisywany w historii wykonań n8n.
const SUPABASE_URL = '$env.SUPABASE_URL';
const SUPABASE_KEY = '$env.SUPABASE_SERVICE_KEY';

// Wywołanie funkcji SQL przez PostgREST. `body` to wyrażenie JS zwracające obiekt z argumentami.
// Funkcje zwracają obiekty lub tabele (nie skalary), bo n8n źle parsuje gołe wartości JSON.
const rpc = (name, position, fn, body, extra = {}, options = {}) =>
  node(name, 'n8n-nodes-base.httpRequest', 4.2, position, {
    method: 'POST',
    url: `={{ ${SUPABASE_URL} }}/rest/v1/rpc/${fn}`,
    sendHeaders: true,
    headerParameters: {
      parameters: [
        { name: 'apikey', value: `={{ ${SUPABASE_KEY} }}` },
        { name: 'Authorization', value: `=Bearer {{ ${SUPABASE_KEY} }}` },
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

// Ustawienia niebędące sekretami. INTAKE_TOKEN jest porównywany tutaj, a do danych trafia tylko wynik.
const configNode = (position, name = 'Config') => {
  const env = (name, fallback) => `={{ $env.${name} || '${fallback}' }}`;
  const set = (name, value, type = 'string') => ({ id: `cfg-${name}`, name, value, type });
  return node(name, 'n8n-nodes-base.set', 3.4, position, {
    mode: 'manual',
    assignments: {
      assignments: [
        set('projectDir', '={{ $env.PROJECT_DIR }}'),
        set('allowMock', env('ALLOW_LLM_MOCK', '0')),
        set('ownerEmail', env('OWNER_EMAIL', 'owner@example.com')),
        set('publicUrl', env('PUBLIC_URL', 'http://localhost:5678')),
        set('team', env('TEAM', 'Jan,Anna,Piotr')),
        // tylko wartości niebędące sekretami: adres webhooka Slacka i hasło Gmaila czytamy bezpośrednio z $env w węzłach
        set('slackConfigured', '={{ !!$env.SLACK_WEBHOOK_URL }}', 'boolean'),
        set('emailDelivery', env('EMAIL_DELIVERY', 'off')),
        set('emailAllowlist', `={{ $env.EMAIL_ALLOWLIST || $env.GMAIL_USER || '' }}`),
        set('authorized',
          `={{ !$env.INTAKE_TOKEN || ($json.headers && $json.headers['x-intake-token'] === $env.INTAKE_TOKEN) }}`, 'boolean'),
      ],
    },
    includeOtherFields: true,
    options: {},
  });
};

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

// Wspólny koniec obu przepływów: kontekst zamówienia z bazy -> maile -> email_outbox.
// Maile zawsze wynikają ze stanu w bazie, więc sweeper odtwarza je tą samą ścieżką.
const queueEmailNode = (position) =>
  rpc('Queue email', position, 'enqueue_email',
    `{ p_order_id: $json.order_id, p_kind: $json.kind, p_to: $json.to, p_subject: $json.subject, p_body: $json.body }`,
    // jeden nieudany mail nie zatrzymuje pozostałych; brakujące uzupełni sweeper
    { onError: 'continueRegularOutput' },
    // funkcja zwraca sam uuid albo NULL, a wynik nie jest używany
    { response: { response: { responseFormat: 'text' } } });

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
// Kolejność ma znaczenie: zgłoszenie jest zapisywane w bazie (Receive) ZANIM webhook odpowie 200
// i zanim ruszy AI. Atomowy INSERT rozstrzyga też wyścig dwóch żądań z tym samym external_id.

function buildIntake() {
  const promptTemplate = JSON.stringify(prompt('parse-order'));
  const nodes = [
    node('Webhook', 'n8n-nodes-base.webhook', 2.1, [0, 0], {
      httpMethod: 'POST', path: 'order', responseMode: 'responseNode', options: {},
    }, { webhookId: 'order-intake-0001' }),
    configNode([220, 0]),
    codeNode('Normalize', [440, 0], code('normalize')),
    boolIf('Valid input?', [660, 0], '$json.valid'),
    rpc('Receive', [880, -100], 'intake_receive',
      `{ p: { external_id: $json.external_id, source: $json.source, customer_email: $json.customer_email, raw_text: $json.message } }`),
    node('Accepted', 'n8n-nodes-base.respondToWebhook', 1.1, [1100, -100], {
      respondWith: 'json',
      responseBody: `={{ { external_id: $('Normalize').first().json.external_id, status: $json.created ? 'processing' : 'duplicate' } }}`,
      options: { responseCode: 200 },
    }),
    node('Rejected', 'n8n-nodes-base.respondToWebhook', 1.1, [880, 120], {
      respondWith: 'json',
      responseBody: `={{ { error: $json.errors.includes('unauthorized') ? 'UNAUTHORIZED' : 'INVALID_INPUT', fields: $json.errors } }}`,
      options: { responseCode: `={{ $json.errors.includes('unauthorized') ? 401 : 400 }}` },
    }),
    boolIf('First delivery?', [1320, -100], '$json.created'),
    rpc('Catalog', [1540, -100], 'catalog_for_llm', '{}'),
    codeNode('Build prompt', [1760, -100], code('build-prompt').replace('__PROMPT_TEMPLATE__', promptTemplate)),
    node('Ask LLM', 'n8n-nodes-base.executeWorkflow', 1.2, [1980, -100], {
      source: 'database',
      workflowId: { __rl: true, value: LLM_WORKFLOW_ID, mode: 'id' },
      options: { waitForSubWorkflow: true },
    }),
    codeNode('Validate', [2200, -100], code('validate-llm')),
    rpc('Complete', [2420, -100], 'intake_complete',
      `{ p_order_id: $('Receive').first().json.order_id, p: $json.payload }`),
    rpc('Context', [2640, -100], 'notification_context', `{ p_order_id: $('Receive').first().json.order_id }`),
    codeNode('Compose emails', [2860, -100], code('compose-emails')),
    queueEmailNode([3080, -100]),
  ];

  return workflow(INTAKE_WORKFLOW_ID, '01 Order intake', nodes, [
    ['Webhook', 'Config'], ['Config', 'Normalize'], ['Normalize', 'Valid input?'],
    ['Valid input?', 'Receive', 0], ['Valid input?', 'Rejected', 1],
    ['Receive', 'Accepted'], ['Accepted', 'First delivery?'], ['First delivery?', 'Catalog', 0],
    ['Catalog', 'Build prompt'], ['Build prompt', 'Ask LLM'], ['Ask LLM', 'Validate'],
    ['Validate', 'Complete'], ['Complete', 'Context'], ['Context', 'Compose emails'],
    ['Compose emails', 'Queue email'],
  ]);
}

// --- 02-intake-sweeper -----------------------------------------------------------------------
// Co 5 minut: zgłoszenia niedomknięte po 10 min trafiają do ręcznego sprawdzenia, a zamówieniom
// bez kompletu maili uzupełniamy brakujące. Webhook /sweep działa tylko w trybie testowym.

function buildSweeper() {
  const nodes = [
    node('Schedule', 'n8n-nodes-base.scheduleTrigger', 1.2, [0, 0], {
      rule: { interval: [{ field: 'minutes', minutesInterval: 5 }] },
    }),
    node('Webhook', 'n8n-nodes-base.webhook', 2.1, [0, 220], {
      httpMethod: 'POST', path: 'sweep', responseMode: 'responseNode', options: {},
    }, { webhookId: 'intake-sweep-0001' }),
    configNode([220, 100]),
    codeNode('Params', [440, 100], code('sweep-params')),
    boolIf('Allowed?', [660, 100], '$json.allowed'),
    node('Forbidden', 'n8n-nodes-base.respondToWebhook', 1.1, [880, 260], {
      respondWith: 'json', responseBody: `={{ { error: 'FORBIDDEN' } }}`, options: { responseCode: 403 },
    }),
    boolIf('Via webhook?', [880, 20], '$json.viaWebhook'),
    node('Started', 'n8n-nodes-base.respondToWebhook', 1.1, [1100, -60], {
      respondWith: 'json', responseBody: `={{ { status: 'started' } }}`, options: { responseCode: 200 },
    }),
    rpc('Mark stuck', [1320, 20], 'mark_stuck_intakes', `{ p_older_than_seconds: $('Params').first().json.stuckAfter }`),
    rpc('Missing notifications', [1540, 20], 'orders_missing_notifications',
      `{ p_older_than_seconds: $('Params').first().json.notifyAfter }`),
    rpc('Context', [1760, 20], 'notification_context', `{ p_order_id: $json.order_id }`),
    codeNode('Compose emails', [1980, 20], code('compose-emails')),
    queueEmailNode([2200, 20]),
  ];

  return workflow(SWEEPER_WORKFLOW_ID, '02 Intake sweeper', nodes, [
    ['Schedule', 'Config'], ['Webhook', 'Config'], ['Config', 'Params'], ['Params', 'Allowed?'],
    ['Allowed?', 'Via webhook?', 0], ['Allowed?', 'Forbidden', 1],
    ['Via webhook?', 'Started', 0], ['Via webhook?', 'Mark stuck', 1], ['Started', 'Mark stuck'],
    ['Mark stuck', 'Missing notifications'], ['Missing notifications', 'Context'],
    ['Context', 'Compose emails'], ['Compose emails', 'Queue email'],
  ]);
}


// --- 03-team-tasks ---------------------------------------------------------------------------
// Linki z maila i ze Slacka: GET pokazuje stronę z przyciskiem (skanery linków w poczcie nie mogą
// niczego zatwierdzić), a dopiero POST z formularza zmienia stan i dopisuje powiadomienia do kolejek.

function buildTeamTasks() {
  const forConfig = (src, cfgName) => src.split("$('Config')").join(`$('${cfgName}')`);
  const hook = (name, method, path, y, id) =>
    node(name, 'n8n-nodes-base.webhook', 2.1, [0, y], { httpMethod: method, path, responseMode: 'responseNode', options: {} },
      { webhookId: id });

  const nodes = [
    // GET /approve?order_id=... -> strona z formularzem
    hook('GET approve', 'GET', 'approve', 0, 'team-approve-get'),
    configNode([220, 0], 'Config page'),
    codeNode('Parse approve page', [440, 0], code('id-prep')),
    boolIf('Approve link valid?', [660, 0], '$json.valid'),
    rpc('Order context', [880, -60], 'notification_context', `{ p_order_id: $json.id }`),
    codeNode('Approve page', [1100, -60], forConfig(code('approve-page'), 'Config page')),

    // POST /approve -> zlecenie zadania
    hook('POST approve', 'POST', 'approve', 260, 'team-approve-post'),
    configNode([220, 260], 'Config POST'),
    codeNode('Parse approve', [440, 260], code('id-prep')),
    boolIf('Approve form valid?', [660, 260], '$json.valid'),
    rpc('Approve order', [880, 200], 'approve_order', `{ p_order_id: $json.id, p_assignee: $json.assignee }`),
    codeNode('Approve result', [1100, 200], forConfig(code('approve-result'), 'Config POST')),

    // GET /task-done?task_id=... -> strona z przyciskiem
    hook('GET task-done', 'GET', 'task-done', 520, 'team-done-get'),
    codeNode('Parse done page', [440, 520], code('id-prep')),
    codeNode('Done page', [660, 520], code('done-page')),

    // POST /task-done -> zamknięcie zadania
    hook('POST task-done', 'POST', 'task-done', 700, 'team-done-post'),
    codeNode('Parse done', [440, 700], code('id-prep')),
    boolIf('Done form valid?', [660, 700], '$json.valid'),
    rpc('Task done', [880, 640], 'task_done', `{ p_task_id: $json.id }`),
    codeNode('Done result', [1100, 640], code('done-result')),

    // wspólny koniec łańcuchów POST i odpowiedzi
    rpc('Queue notifications', [1320, 420], 'enqueue_notifications', `{ p: $json.notifications }`,
      { onError: 'continueRegularOutput' }, { response: { response: { responseFormat: 'json' } } }),
    codeNode('Final page', [1540, 420], code('final-page')),
    codeNode('Bad link', [880, 460], code('bad-link')),
    node('Respond page', 'n8n-nodes-base.respondToWebhook', 1.1, [1760, 260], {
      respondWith: 'text',
      responseBody: '={{ $json.html }}',
      options: {
        responseCode: '={{ $json.code }}',
        responseHeaders: { entries: [{ name: 'Content-Type', value: 'text/html; charset=utf-8' }] },
      },
    }),
  ];

  return workflow(TEAM_WORKFLOW_ID, '03 Team tasks', nodes, [
    ['GET approve', 'Config page'], ['Config page', 'Parse approve page'], ['Parse approve page', 'Approve link valid?'],
    ['Approve link valid?', 'Order context', 0], ['Approve link valid?', 'Bad link', 1],
    ['Order context', 'Approve page'], ['Approve page', 'Respond page'],

    ['POST approve', 'Config POST'], ['Config POST', 'Parse approve'], ['Parse approve', 'Approve form valid?'],
    ['Approve form valid?', 'Approve order', 0], ['Approve form valid?', 'Bad link', 1],
    ['Approve order', 'Approve result'], ['Approve result', 'Queue notifications'],

    ['GET task-done', 'Parse done page'], ['Parse done page', 'Done page'], ['Done page', 'Respond page'],

    ['POST task-done', 'Parse done'], ['Parse done', 'Done form valid?'],
    ['Done form valid?', 'Task done', 0], ['Done form valid?', 'Bad link', 1],
    ['Task done', 'Done result'], ['Done result', 'Queue notifications'],

    ['Queue notifications', 'Final page'], ['Final page', 'Respond page'], ['Bad link', 'Respond page'],
  ]);
}


// --- 04-stock-prices ---------------------------------------------------------------------------
// Codziennie o 7:00: wczytuje cenniki z data/suppliers/*.csv, aktualizuje ceny w bazie i wysyła
// właścicielowi podsumowanie: co zamówić i u kogo najtaniej. Webhook /stock-report działa tylko w trybie testowym.

function buildStock() {
  const nodes = [
    node('Schedule 7:00', 'n8n-nodes-base.scheduleTrigger', 1.2, [0, 0], {
      rule: { interval: [{ field: 'cronExpression', expression: '0 7 * * *' }] },
    }),
    node('Webhook', 'n8n-nodes-base.webhook', 2.1, [0, 220], {
      httpMethod: 'POST', path: 'stock-report', responseMode: 'responseNode', options: {},
    }, { webhookId: 'stock-report-0001' }),
    configNode([220, 100]),
    codeNode('Stock params', [440, 100], code('stock-params')),
    boolIf('Allowed?', [660, 100], '$json.allowed'),
    node('Forbidden', 'n8n-nodes-base.respondToWebhook', 1.1, [880, 260], {
      respondWith: 'json', responseBody: `={{ { error: 'FORBIDDEN' } }}`, options: { responseCode: 403 },
    }),
    boolIf('Via webhook?', [880, 20], '$json.viaWebhook'),
    node('Started', 'n8n-nodes-base.respondToWebhook', 1.1, [1100, -60], {
      respondWith: 'json', responseBody: `={{ { status: 'started' } }}`, options: { responseCode: 200 },
    }),
    node('Read CSV', 'n8n-nodes-base.executeCommand', 1, [1320, 20], {
      command: `=cat "{{ $json.projectDir }}"/data/{{ $json.dir }}/*.csv`,
    }, { onError: 'continueRegularOutput' }),
    codeNode('Parse CSV', [1540, 20], code('csv-parse')),
    rpc('Import prices', [1760, 20], 'import_supplier_prices', `{ p: { rows: $json.rows } }`,
      { onError: 'continueRegularOutput' }),
    rpc('Stock report', [1980, 20], 'low_stock_report', '{}'),
    codeNode('Digest', [2200, 20], code('stock-digest')),
    rpc('Queue notifications', [2420, 20], 'enqueue_notifications', `{ p: $json.p }`, { onError: 'continueRegularOutput' }),
  ];

  return workflow(STOCK_WORKFLOW_ID, '04 Stock and prices', nodes, [
    ['Schedule 7:00', 'Config'], ['Webhook', 'Config'], ['Config', 'Stock params'], ['Stock params', 'Allowed?'],
    ['Allowed?', 'Via webhook?', 0], ['Allowed?', 'Forbidden', 1],
    ['Via webhook?', 'Started', 0], ['Via webhook?', 'Read CSV', 1], ['Started', 'Read CSV'],
    ['Read CSV', 'Parse CSV'], ['Parse CSV', 'Import prices'], ['Import prices', 'Stock report'],
    ['Stock report', 'Digest'], ['Digest', 'Queue notifications'],
  ]);
}


// --- 05-deliver --------------------------------------------------------------------------------
// Co minutę wysyła to, co czeka w slack_outbox i email_outbox. Slack idzie przez Incoming Webhook,
// maile przez Gmail SMTP, ale domyślnie są wyłączone i trafiają wyłącznie na adresy z listy dozwolonych.
// Wiadomość jest oznaczana jako wysłana dopiero po potwierdzeniu przez Slack (odpowiedź "ok") albo SMTP.

function buildDeliver() {
  const nodes = [
    node('Schedule', 'n8n-nodes-base.scheduleTrigger', 1.2, [0, 0], {
      rule: { interval: [{ field: 'minutes', minutesInterval: 1 }] },
    }),
    node('Webhook', 'n8n-nodes-base.webhook', 2.1, [0, 220], {
      httpMethod: 'POST', path: 'deliver', responseMode: 'responseNode', options: {},
    }, { webhookId: 'deliver-0001' }),
    configNode([220, 100]),
    codeNode('Deliver params', [440, 100], code('deliver-params')),
    boolIf('Allowed?', [660, 100], '$json.allowed'),
    node('Forbidden', 'n8n-nodes-base.respondToWebhook', 1.1, [880, 260], {
      respondWith: 'json', responseBody: `={{ { error: 'FORBIDDEN' } }}`, options: { responseCode: 403 },
    }),
    boolIf('Via webhook?', [880, 20], '$json.viaWebhook'),
    node('Started', 'n8n-nodes-base.respondToWebhook', 1.1, [1100, -60], {
      respondWith: 'json', responseBody: `={{ { status: 'started' } }}`, options: { responseCode: 200 },
    }),
    boolIf('Run now?', [1320, 20], '$json.run'),
    rpc('Pending', [1540, 20], 'pending_deliveries',
      `{ p_limit: 20, p_only_test: $('Deliver params').first().json.onlyTest }`),
    codeNode('Plan', [1760, 20], code('deliver-plan')),
    node('Route', 'n8n-nodes-base.switch', 3.2, [1980, 20], {
      mode: 'expression', numberOutputs: 3,
      output: `={{ ({ 'slack:send': 0, 'email:send': 1 })[$json.route] ?? 2 }}`,
    }),
    node('Send Slack', 'n8n-nodes-base.httpRequest', 4.2, [1980, -80], {
      method: 'POST',
      url: `={{ $('Deliver params').first().json.slackUrl || $env.SLACK_WEBHOOK_URL }}`,
      sendBody: true, contentType: 'json', specifyBody: 'json',
      jsonBody: `={{ JSON.stringify({ text: $json.text }) }}`,
      options: { timeout: 10000, response: { response: { responseFormat: 'text' } } },
    }, { onError: 'continueRegularOutput' }),
    boolIf('Slack confirmed?', [2200, -80], `$json.data === 'ok'`),
    node('Send email', 'n8n-nodes-base.emailSend', 2.1, [1980, 120], {
      fromEmail: `={{ $env.GMAIL_USER }}`, toEmail: `={{ $json.to }}`, subject: `={{ $json.subject }}`,
      emailFormat: 'text', text: `={{ $json.text }}`, options: {},
    }, { onError: 'continueRegularOutput', credentials: { smtp: SMTP_CREDENTIAL } }),
    boolIf('Email sent?', [2200, 120], `!$json.error`),
    node('Skip', 'n8n-nodes-base.noOp', 1, [1980, 300], {}),
    rpc('Mark delivered', [2420, 20], 'mark_delivered',
      `{ p_channel: $('Plan').item.json.channel, p_id: $('Plan').item.json.id }`),
  ];

  return workflow(DELIVER_WORKFLOW_ID, '05 Deliver', nodes, [
    ['Schedule', 'Config'], ['Webhook', 'Config'], ['Config', 'Deliver params'], ['Deliver params', 'Allowed?'],
    ['Allowed?', 'Via webhook?', 0], ['Allowed?', 'Forbidden', 1],
    ['Via webhook?', 'Started', 0], ['Via webhook?', 'Run now?', 1], ['Started', 'Run now?'],
    ['Run now?', 'Pending', 0], ['Pending', 'Plan'], ['Plan', 'Route'],
    ['Route', 'Send Slack', 0], ['Route', 'Send email', 1], ['Route', 'Skip', 2],
    ['Send Slack', 'Slack confirmed?'], ['Slack confirmed?', 'Mark delivered', 0],
    ['Send email', 'Email sent?'], ['Email sent?', 'Mark delivered', 0],
  ]);
}

// --- zapis -------------------------------------------------------------------------------------

const outDir = join(root, 'workflows');
mkdirSync(outDir, { recursive: true });
for (const [file, wf] of [
  ['00-llm.json', buildLlm()],
  ['01-order-intake.json', buildIntake()],
  ['02-intake-sweeper.json', buildSweeper()],
  ['03-team-tasks.json', buildTeamTasks()],
  ['04-stock-prices.json', buildStock()],
  ['05-deliver.json', buildDeliver()],
]) {
  writeFileSync(join(outDir, file), JSON.stringify(wf, null, 2) + '\n');
  console.log(`zapisano n8n/workflows/${file} (${wf.nodes.length} węzłów)`);
}
