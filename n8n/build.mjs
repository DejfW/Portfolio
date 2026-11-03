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
const CALC_WORKFLOW_ID = 'calc00000000001';
const REPORT_WORKFLOW_ID = 'report000000001';
const PO_WORKFLOW_ID = 'po0000000000001';
const FOLLOWUP_WORKFLOW_ID = 'followup0000001';
const TRIAGE_WORKFLOW_ID = 'triage000000001';
const SMTP_CREDENTIAL = { id: 'smtpgmail000001', name: 'Gmail SMTP' };
const OPERATOR_CREDENTIAL = { id: 'operatorauth0001', name: 'Operator' };

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
        set('testSinkPort', env('TEST_SINK_PORT', '18765')),
        set('slackConfigured', '={{ !!$env.SLACK_WEBHOOK_URL }}', 'boolean'),
        set('emailDelivery', env('EMAIL_DELIVERY', 'off')),
        set('emailAllowlist', `={{ $env.EMAIL_ALLOWLIST || $env.GMAIL_USER || '' }}`),
        // sam fakt ustawienia sekretu (nie jego wartość): endpointy kosztowne (triage) bez sekretu odrzucają żądania
        set('tokenSet', `={{ !!$env.INTAKE_TOKEN }}`, 'boolean'),
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
  // Błędne wykonania nie zapisują danych: żądania HTTP w błędach zawierają nagłówki (klucz Supabase) i adres webhooka Slacka.
  settings: { executionOrder: 'v1', saveDataErrorExecution: 'none' }, versionId: `${id}-v1`,
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
// niczego zatwierdzić), a dopiero POST z formularza zmienia stan. Powiadomienia zapisuje baza w tej samej transakcji.

function buildTeamTasks() {
  const forConfig = (src, cfgName) => src.split("$('Config')").join(`$('${cfgName}')`);
  const hook = (name, method, path, y, id) =>
    // linki w mailach i na Slacku prowadzą do tych webhooków, więc wymagają logowania operatora (Basic),
    // a sam identyfikator zamówienia w adresie nie daje dostępu
    node(name, 'n8n-nodes-base.webhook', 2.1, [0, y],
      { httpMethod: method, path, authentication: 'basicAuth', responseMode: 'responseNode', options: {} },
      { webhookId: id, credentials: { httpBasicAuth: OPERATOR_CREDENTIAL } });

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
    codeNode('Parse approve', [440, 260], code('id-prep-post')),
    boolIf('Approve form valid?', [660, 260], '$json.valid'),
    rpc('Approve order', [880, 200], 'approve_order',
      `{ p_order_id: $json.id, p_assignee: $json.assignee, p_public_url: $('Config POST').first().json.publicUrl }`),
    codeNode('Approve result', [1100, 200], forConfig(code('approve-result'), 'Config POST')),

    // GET /task-done?task_id=... -> strona z przyciskiem
    hook('GET task-done', 'GET', 'task-done', 520, 'team-done-get'),
    codeNode('Parse done page', [440, 520], code('id-prep')),
    codeNode('Done page', [660, 520], code('done-page')),

    // POST /task-done -> zamknięcie zadania
    hook('POST task-done', 'POST', 'task-done', 700, 'team-done-post'),
    codeNode('Parse done', [440, 700], code('id-prep-post')),
    boolIf('Done form valid?', [660, 700], '$json.valid'),
    rpc('Task done', [880, 640], 'task_done', `{ p_task_id: $json.id }`),
    codeNode('Done result', [1100, 640], code('done-result')),

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
    ['Approve order', 'Approve result'], ['Approve result', 'Respond page'],

    ['GET task-done', 'Parse done page'], ['Parse done page', 'Done page'], ['Done page', 'Respond page'],

    ['POST task-done', 'Parse done'], ['Parse done', 'Done form valid?'],
    ['Done form valid?', 'Task done', 0], ['Done form valid?', 'Bad link', 1],
    ['Task done', 'Done result'], ['Done result', 'Respond page'],

    ['Bad link', 'Respond page'],
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
      // po każdym pliku dodajemy nową linię, żeby brak końcowego LF nie skleił ostatniego wiersza z początkiem następnego pliku
      command: `=for f in "{{ $json.projectDir }}"/data/{{ $json.dir }}/*.csv; do [ -e "$f" ] && { cat "$f"; printf '\\n'; }; done`,
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
// Wiadomość jest oznaczana jako wysłana dopiero po potwierdzeniu przez Slack (odpowiedź "ok") albo SMTP;
// niepowodzenie trafia do mark_failed (ponowienie po 2, 4, 8... minutach, rezygnacja po 8 próbach).

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
    rpc('Claim', [1540, 20], 'claim_deliveries',
      `{ p_limit: 20, p_only_test: $('Deliver params').first().json.onlyTest, p_slack: $('Deliver params').first().json.slackReady, ` +
      `p_email: $('Deliver params').first().json.emailOn, p_allowlist: $('Deliver params').first().json.allowlist }`),
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
      options: { timeout: 10000, redirect: { redirect: { followRedirects: false } }, response: { response: { responseFormat: 'text' } } },
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
    codeNode('Failure reason', [2420, 300], code('deliver-error')),
    rpc('Mark failed', [2640, 300], 'mark_failed',
      `{ p_channel: $('Plan').item.json.channel, p_id: $('Plan').item.json.id, p_error: $json.text }`),
  ];

  return workflow(DELIVER_WORKFLOW_ID, '05 Deliver', nodes, [
    ['Schedule', 'Config'], ['Webhook', 'Config'], ['Config', 'Deliver params'], ['Deliver params', 'Allowed?'],
    ['Allowed?', 'Via webhook?', 0], ['Allowed?', 'Forbidden', 1],
    ['Via webhook?', 'Started', 0], ['Via webhook?', 'Run now?', 1], ['Started', 'Run now?'],
    ['Run now?', 'Claim', 0], ['Claim', 'Plan'], ['Plan', 'Route'],
    ['Route', 'Send Slack', 0], ['Route', 'Send email', 1], ['Route', 'Skip', 2],
    ['Send Slack', 'Slack confirmed?'], ['Slack confirmed?', 'Mark delivered', 0], ['Slack confirmed?', 'Failure reason', 1],
    ['Send email', 'Email sent?'], ['Email sent?', 'Mark delivered', 0], ['Email sent?', 'Failure reason', 1],
    ['Failure reason', 'Mark failed'],
  ]);
}


// --- 06-calculator ---------------------------------------------------------------------------
// API publicznego kalkulatora (strona: web/index.html, serwowana przez scripts/serve-web.mjs albo dowolny hosting statyczny).
// GET /catalog daje listę produktów i materiałów bez cen, POST /quote-preview liczy wycenę na żywo bez zapisu
// (tylko ceny sprzedaży), a POST /calculator-order zapisuje zamówienie z gotowych pozycji i wysyła maile (bez parsera AI).
// CORS jest otwarty, bo dane są publiczne i nie ma ciasteczek. Ograniczanie liczby żądań (rate limit, antybot) należy
// do warstwy przed n8n (reverse proxy), bo n8n nie ma wbudowanego limitu.

function buildCalculator() {
  const cors = { allowedOrigins: '*' };
  const json = (name, position, code) => node(name, 'n8n-nodes-base.respondToWebhook', 1.1, position, {
    respondWith: 'json', responseBody: `={{ $json }}`,
    options: { responseCode: code, responseHeaders: { entries: [{ name: 'Cache-Control', value: 'no-store' }] } },
  });
  const nodes = [
    node('Catalog webhook', 'n8n-nodes-base.webhook', 2.1, [0, 220], {
      httpMethod: 'GET', path: 'catalog', responseMode: 'responseNode', options: cors,
    }, { webhookId: 'calculator-catalog-0001' }),
    rpc('Read catalog', [260, 220], 'catalog_for_calculator', '{}'),
    json('Catalog response', [520, 220], 200),
    node('Order webhook', 'n8n-nodes-base.webhook', 2.1, [0, 660], {
      httpMethod: 'POST', path: 'calculator-order', responseMode: 'responseNode', options: cors,
    }, { webhookId: 'calculator-order-0001' }),
    configNode([260, 660]),
    rpc('Create order', [480, 660], 'calculator_order', `{ p: $('Order webhook').first().json.body }`),
    boolIf('Order error?', [700, 660], '!!$json.error'),
    node('Order rejected', 'n8n-nodes-base.respondToWebhook', 1.1, [920, 760], {
      respondWith: 'json', responseBody: `={{ { error: $json.error } }}`, options: { responseCode: 422 },
    }),
    node('Order accepted', 'n8n-nodes-base.respondToWebhook', 1.1, [920, 560], {
      respondWith: 'json', responseBody: `={{ { status: $json.created ? 'received' : 'duplicate' } }}`, options: { responseCode: 200 },
    }),
    boolIf('Created?', [1140, 560], '$json.created'),
    rpc('Context', [1360, 560], 'notification_context', `{ p_order_id: $('Create order').first().json.order_id }`),
    codeNode('Compose emails', [1580, 560], code('compose-emails')),
    queueEmailNode([1800, 560]),
    node('Preview webhook', 'n8n-nodes-base.webhook', 2.1, [0, 440], {
      httpMethod: 'POST', path: 'quote-preview', responseMode: 'responseNode', options: cors,
    }, { webhookId: 'calculator-preview-0001' }),
    rpc('Preview', [260, 440], 'quote_preview', `{ p: $json.body }`),
    node('Preview response', 'n8n-nodes-base.respondToWebhook', 1.1, [520, 440], {
      respondWith: 'json', responseBody: `={{ $json }}`,
      options: {
        responseCode: `={{ $json.error ? 422 : 200 }}`,
        responseHeaders: { entries: [{ name: 'Cache-Control', value: 'no-store' }] },
      },
    }),
  ];
  return workflow(CALC_WORKFLOW_ID, '06 Customer calculator', nodes, [
    ['Catalog webhook', 'Read catalog'], ['Read catalog', 'Catalog response'],
    ['Preview webhook', 'Preview'], ['Preview', 'Preview response'],
    ['Order webhook', 'Config'], ['Config', 'Create order'], ['Create order', 'Order error?'],
    ['Order error?', 'Order rejected', 0], ['Order error?', 'Order accepted', 1],
    ['Order accepted', 'Created?'], ['Created?', 'Context', 0], ['Context', 'Compose emails'],
    ['Compose emails', 'Queue email'],
  ]);
}

// --- 07-weekly-report ------------------------------------------------------------------------
// W poniedziałek o 8:00: bestsellery z 7 i 30 dni liczy baza, AI pisze 5-zdaniowe podsumowanie z rekomendacją,
// a całość trafia do kolejki Slack (klucz deduplikacji = tydzień). Webhook /weekly-report działa tylko w trybie testowym.

function buildReport() {
  const promptTemplate = JSON.stringify(prompt('weekly-report'));
  const nodes = [
    node('Schedule Monday 8:00', 'n8n-nodes-base.scheduleTrigger', 1.2, [0, 0], {
      rule: { interval: [{ field: 'cronExpression', expression: '0 8 * * 1' }] },
    }),
    node('Webhook', 'n8n-nodes-base.webhook', 2.1, [0, 220], {
      httpMethod: 'POST', path: 'weekly-report', responseMode: 'responseNode', options: {},
    }, { webhookId: 'weekly-report-0001' }),
    configNode([220, 100]),
    codeNode('Report params', [440, 100], code('report-params')),
    boolIf('Allowed?', [660, 100], '$json.allowed'),
    node('Forbidden', 'n8n-nodes-base.respondToWebhook', 1.1, [880, 260], {
      respondWith: 'json', responseBody: `={{ { error: 'FORBIDDEN' } }}`, options: { responseCode: 403 },
    }),
    boolIf('Via webhook?', [880, 20], '$json.viaWebhook'),
    node('Started', 'n8n-nodes-base.respondToWebhook', 1.1, [1100, -60], {
      respondWith: 'json', responseBody: `={{ { status: 'started' } }}`, options: { responseCode: 200 },
    }),
    rpc('Report data', [1320, 20], 'weekly_report', '{}'),
    codeNode('Report prompt', [1540, 20], code('report-prompt').replace('__PROMPT_TEMPLATE__', promptTemplate)),
    node('Ask LLM', 'n8n-nodes-base.executeWorkflow', 1.2, [1760, 20], {
      source: 'database',
      workflowId: { __rl: true, value: LLM_WORKFLOW_ID, mode: 'id' },
      options: { waitForSubWorkflow: true },
      // błąd podworkflow (np. zbyt duży prompt) nie może zgubić raportu liczbowego: Compose pokaże wersję bez AI
    }, { onError: 'continueRegularOutput' }),
    codeNode('Compose report', [1980, 20], code('report-compose')),
    rpc('Queue notifications', [2200, 20], 'enqueue_notifications', `{ p: $json.p }`, { onError: 'continueRegularOutput' }),
  ];
  return workflow(REPORT_WORKFLOW_ID, '07 Weekly report', nodes, [
    ['Schedule Monday 8:00', 'Config'], ['Webhook', 'Config'], ['Config', 'Report params'], ['Report params', 'Allowed?'],
    ['Allowed?', 'Via webhook?', 0], ['Allowed?', 'Forbidden', 1],
    ['Via webhook?', 'Started', 0], ['Via webhook?', 'Report data', 1], ['Started', 'Report data'],
    ['Report data', 'Report prompt'], ['Report prompt', 'Ask LLM'], ['Ask LLM', 'Compose report'],
    ['Compose report', 'Queue notifications'],
  ]);
}


// --- 08-purchase-orders ------------------------------------------------------------------------
// Codziennie o 7:15 (po imporcie cen z workflow 04) tworzy szkice zamówień do hurtowni z materiałów poniżej minimum
// i wysyła właścicielowi na Slacka link zatwierdzenia. Zatwierdzenie (strona z przyciskiem, logowanie Basic) wysyła mail
// do hurtowni, a potwierdzenie dostawy zwiększa stan magazynu. Webhook /po-run działa tylko w trybie testowym.

function buildPurchasing() {
  const hook = (name, method, path, y, id) =>
    node(name, 'n8n-nodes-base.webhook', 2.1, [0, y],
      { httpMethod: method, path, authentication: 'basicAuth', responseMode: 'responseNode', options: {} },
      { webhookId: id, credentials: { httpBasicAuth: OPERATOR_CREDENTIAL } });

  const nodes = [
    node('Schedule 7:15', 'n8n-nodes-base.scheduleTrigger', 1.2, [0, 0], {
      rule: { interval: [{ field: 'cronExpression', expression: '15 7 * * *' }] },
    }),
    node('Webhook run', 'n8n-nodes-base.webhook', 2.1, [0, 220], {
      httpMethod: 'POST', path: 'po-run', responseMode: 'responseNode', options: {},
    }, { webhookId: 'po-run-0001' }),
    configNode([220, 100]),
    codeNode('PO params', [440, 100], code('po-params')),
    boolIf('Allowed?', [660, 100], '$json.allowed'),
    node('Forbidden', 'n8n-nodes-base.respondToWebhook', 1.1, [880, 260], {
      respondWith: 'json', responseBody: `={{ { error: 'FORBIDDEN' } }}`, options: { responseCode: 403 },
    }),
    boolIf('Via webhook?', [880, 20], '$json.viaWebhook'),
    node('Started', 'n8n-nodes-base.respondToWebhook', 1.1, [1100, -60], {
      respondWith: 'json', responseBody: `={{ { status: 'started' } }}`, options: { responseCode: 200 },
    }),
    rpc('Create POs', [1320, 20], 'create_purchase_orders', `{ p_public_url: $('Config').first().json.publicUrl }`),

    // GET /po-approve?po_id=... -> strona z przyciskiem
    hook('GET po-approve', 'GET', 'po-approve', 520, 'po-approve-get'),
    codeNode('Parse approve page', [440, 520], code('id-prep')),
    boolIf('Approve link valid?', [660, 520], '$json.valid'),
    rpc('PO context approve', [880, 460], 'purchase_order_context', `{ p_po_id: $json.id }`),
    codeNode('Approve page', [1100, 460], code('po-approve-page')),

    // POST /po-approve -> zatwierdzenie
    hook('POST po-approve', 'POST', 'po-approve', 740, 'po-approve-post'),
    configNode([220, 740], 'Config POST approve'),
    codeNode('Parse approve', [440, 740], code('id-prep-post')),
    boolIf('Approve form valid?', [660, 740], '$json.valid'),
    rpc('Approve PO', [880, 680], 'approve_purchase_order', `{ p_po_id: $json.id }`),
    codeNode('Approve result', [1100, 680], code('po-approve-result')),

    // GET /po-received?po_id=... -> strona z przyciskiem
    hook('GET po-received', 'GET', 'po-received', 960, 'po-received-get'),
    codeNode('Parse receive page', [440, 960], code('id-prep')),
    boolIf('Receive link valid?', [660, 960], '$json.valid'),
    rpc('PO context receive', [880, 900], 'purchase_order_context', `{ p_po_id: $json.id }`),
    codeNode('Receive page', [1100, 900], code('po-receive-page')),

    // POST /po-received -> przyjęcie dostawy
    hook('POST po-received', 'POST', 'po-received', 1180, 'po-received-post'),
    codeNode('Parse receive', [440, 1180], code('id-prep-post')),
    boolIf('Receive form valid?', [660, 1180], '$json.valid'),
    rpc('Receive delivery', [880, 1120], 'receive_delivery', `{ p_po_id: $json.id }`),
    codeNode('Receive result', [1100, 1120], code('po-receive-result')),

    codeNode('Bad link', [880, 1000], code('bad-link')),
    node('Respond page', 'n8n-nodes-base.respondToWebhook', 1.1, [1760, 700], {
      respondWith: 'text',
      responseBody: '={{ $json.html }}',
      options: {
        responseCode: '={{ $json.code }}',
        responseHeaders: { entries: [{ name: 'Content-Type', value: 'text/html; charset=utf-8' }] },
      },
    }),
  ];

  return workflow(PO_WORKFLOW_ID, '08 Purchase orders', nodes, [
    ['Schedule 7:15', 'Config'], ['Webhook run', 'Config'], ['Config', 'PO params'], ['PO params', 'Allowed?'],
    ['Allowed?', 'Via webhook?', 0], ['Allowed?', 'Forbidden', 1],
    ['Via webhook?', 'Started', 0], ['Via webhook?', 'Create POs', 1], ['Started', 'Create POs'],

    ['GET po-approve', 'Parse approve page'], ['Parse approve page', 'Approve link valid?'],
    ['Approve link valid?', 'PO context approve', 0], ['Approve link valid?', 'Bad link', 1],
    ['PO context approve', 'Approve page'], ['Approve page', 'Respond page'],

    ['POST po-approve', 'Config POST approve'], ['Config POST approve', 'Parse approve'], ['Parse approve', 'Approve form valid?'],
    ['Approve form valid?', 'Approve PO', 0], ['Approve form valid?', 'Bad link', 1],
    ['Approve PO', 'Approve result'], ['Approve result', 'Respond page'],

    ['GET po-received', 'Parse receive page'], ['Parse receive page', 'Receive link valid?'],
    ['Receive link valid?', 'PO context receive', 0], ['Receive link valid?', 'Bad link', 1],
    ['PO context receive', 'Receive page'], ['Receive page', 'Respond page'],

    ['POST po-received', 'Parse receive'], ['Parse receive', 'Receive form valid?'],
    ['Receive form valid?', 'Receive delivery', 0], ['Receive form valid?', 'Bad link', 1],
    ['Receive delivery', 'Receive result'], ['Receive result', 'Respond page'],

    ['Bad link', 'Respond page'],
  ]);
}


// --- 09-quote-followup -------------------------------------------------------------------------
// Codziennie o 9:00: wyceny bez odpowiedzi starsze niż 14 dni stają się lost (mail z ankietą), a młodsze dostają
// przypomnienie po 3 i po 7 dniach. Wstęp maila pisze AI (z walidacją i stałym szablonem awaryjnym). Publiczne
// strony ankiety (/lost-reason) są chronione tokenem zamówienia, nie logowaniem. Webhook /followup-run działa tylko
// w trybie testowym.

function buildFollowup() {
  const promptTemplate = JSON.stringify(prompt('followup'));
  const respond = node('Respond page', 'n8n-nodes-base.respondToWebhook', 1.1, [1760, 700], {
    respondWith: 'text',
    responseBody: '={{ $json.html }}',
    options: {
      responseCode: '={{ $json.code }}',
      responseHeaders: { entries: [{ name: 'Content-Type', value: 'text/html; charset=utf-8' }] },
    },
  });
  const publicHook = (name, method, y, id) =>
    node(name, 'n8n-nodes-base.webhook', 2.1, [0, y],
      { httpMethod: method, path: 'lost-reason', responseMode: 'responseNode', options: {} }, { webhookId: id });

  const nodes = [
    node('Schedule 9:00', 'n8n-nodes-base.scheduleTrigger', 1.2, [0, 0], {
      rule: { interval: [{ field: 'cronExpression', expression: '0 9 * * *' }] },
    }),
    node('Webhook run', 'n8n-nodes-base.webhook', 2.1, [0, 220], {
      httpMethod: 'POST', path: 'followup-run', responseMode: 'responseNode', options: {},
    }, { webhookId: 'followup-run-0001' }),
    configNode([220, 100]),
    codeNode('Followup params', [440, 100], code('followup-params')),
    boolIf('Allowed?', [660, 100], '$json.allowed'),
    node('Forbidden', 'n8n-nodes-base.respondToWebhook', 1.1, [880, 260], {
      respondWith: 'json', responseBody: `={{ { error: 'FORBIDDEN' } }}`, options: { responseCode: 403 },
    }),
    boolIf('Via webhook?', [880, 20], '$json.viaWebhook'),
    node('Started', 'n8n-nodes-base.respondToWebhook', 1.1, [1100, -60], {
      respondWith: 'json', responseBody: `={{ { status: 'started' } }}`, options: { responseCode: 200 },
    }),
    // Najpierw zamykamy stare wyceny (mogą nie zwrócić żadnego wiersza, ale przepływ ma iść dalej)
    rpc('Mark lost', [1320, 20], 'mark_lost_quotes', `{ p_days: 14, p_public_url: $('Config').first().json.publicUrl }`,
      { onError: 'continueRegularOutput', alwaysOutputData: true }),
    codeNode('Once', [1540, 20], code('once')),
    rpc('Due follow-ups', [1760, 20], 'quotes_due_followup', '{}'),
    codeNode('Followup prompt', [1980, 20], code('followup-prompt').replace('__PROMPT_TEMPLATE__', promptTemplate)),
    node('Ask LLM', 'n8n-nodes-base.executeWorkflow', 1.2, [2200, 20], {
      source: 'database',
      workflowId: { __rl: true, value: LLM_WORKFLOW_ID, mode: 'id' },
      mode: 'each',
      options: { waitForSubWorkflow: true },
      // awaria modelu nie może zatrzymać przypomnień: Compose użyje stałego szablonu
    }, { onError: 'continueRegularOutput' }),
    codeNode('Compose follow-up', [2420, 20], code('followup-compose')),
    rpc('Record follow-up', [2640, 20], 'record_followup',
      `{ p_order_id: $json.order_id, p_no: $json.followup_no, p_subject: $json.subject, p_body: $json.body }`,
      { onError: 'continueRegularOutput' }, { response: { response: { responseFormat: 'text' } } }),

    // GET /lost-reason?token=... -> strona ankiety (publiczna, token zamówienia)
    publicHook('GET lost-reason', 'GET', 520, 'lost-reason-get'),
    codeNode('Lost prep', [440, 520], code('lost-prep')),
    boolIf('Lost link valid?', [660, 520], '$json.valid'),
    rpc('Lost context', [880, 460], 'lost_reason_context', `{ p_token: $json.token }`),
    codeNode('Lost page', [1100, 460], code('lost-page')),

    // POST /lost-reason -> zapis powodu
    publicHook('POST lost-reason', 'POST', 740, 'lost-reason-post'),
    codeNode('Lost prep POST', [440, 740], code('lost-prep')),
    boolIf('Lost form valid?', [660, 740], '$json.valid'),
    rpc('Record reason', [880, 680], 'record_lost_reason', `{ p_token: $json.token, p_reason: $json.reason }`),
    codeNode('Lost result', [1100, 680], code('lost-result')),

    codeNode('Bad link', [880, 860], code('bad-link')),
    respond,
  ];

  return workflow(FOLLOWUP_WORKFLOW_ID, '09 Quote follow-up', nodes, [
    ['Schedule 9:00', 'Config'], ['Webhook run', 'Config'], ['Config', 'Followup params'], ['Followup params', 'Allowed?'],
    ['Allowed?', 'Via webhook?', 0], ['Allowed?', 'Forbidden', 1],
    ['Via webhook?', 'Started', 0], ['Via webhook?', 'Mark lost', 1], ['Started', 'Mark lost'],
    ['Mark lost', 'Once'], ['Once', 'Due follow-ups'], ['Due follow-ups', 'Followup prompt'],
    ['Followup prompt', 'Ask LLM'], ['Ask LLM', 'Compose follow-up'], ['Compose follow-up', 'Record follow-up'],

    ['GET lost-reason', 'Lost prep'], ['Lost prep', 'Lost link valid?'],
    ['Lost link valid?', 'Lost context', 0], ['Lost link valid?', 'Bad link', 1],
    ['Lost context', 'Lost page'], ['Lost page', 'Respond page'],

    ['POST lost-reason', 'Lost prep POST'], ['Lost prep POST', 'Lost form valid?'],
    ['Lost form valid?', 'Record reason', 0], ['Lost form valid?', 'Bad link', 1],
    ['Record reason', 'Lost result'], ['Lost result', 'Respond page'],

    ['Bad link', 'Respond page'],
  ]);
}


// --- 11-inbox-triage ---------------------------------------------------------------------------
// POST /webhook/triage przyjmuje wiadomość z poczty (to punkt integracji z łącznikiem skrzynki, np. IMAP). AI klasyfikuje ją
// (zamówienie, pytanie, reklamacja, spam), ale o trasie decyduje baza (triage_complete): zamówienie, niepewność i błąd AI
// trafiają do intake (workflow 01 przez POST /webhook/order z tym samym external_id), pytania i reklamacje do właściciela
// na Slacku (pytanie ze szkicem odpowiedzi do akceptacji), a spam jest tylko oznaczany. Workflow nigdy niczego nie wysyła
// klientowi. Co 5 minut druga ścieżka przekazuje do intake wiadomości, które utknęły po awarii.

function buildTriage() {
  const promptTemplate = JSON.stringify(prompt('triage'));
  const faq = JSON.stringify(readFileSync(join(root, '..', 'data', 'faq.md'), 'utf8'));
  const nodes = [
    node('Webhook', 'n8n-nodes-base.webhook', 2.1, [0, 0], {
      httpMethod: 'POST', path: 'triage', responseMode: 'responseNode', options: {},
    }, { webhookId: 'inbox-triage-0001' }),
    configNode([220, 0]),
    codeNode('Triage normalize', [440, 0], code('triage-normalize')),
    boolIf('Valid input?', [660, 0], '$json.valid'),
    rpc('Receive', [880, -100], 'triage_receive',
      `{ p: { external_id: $json.external_id, from_email: $json.from_email, subject: $json.subject, body: $json.message } }`),
    node('Accepted', 'n8n-nodes-base.respondToWebhook', 1.1, [1100, -100], {
      respondWith: 'json',
      responseBody: `={{ { external_id: $('Triage normalize').first().json.external_id, status: $json.created ? 'processing' : 'duplicate' } }}`,
      options: { responseCode: 200 },
    }),
    node('Rejected', 'n8n-nodes-base.respondToWebhook', 1.1, [880, 120], {
      respondWith: 'json',
      responseBody: `={{ { error: $json.errors.includes('unauthorized') ? 'UNAUTHORIZED' : 'INVALID_INPUT', fields: $json.errors } }}`,
      options: { responseCode: `={{ $json.errors.includes('unauthorized') ? 401 : 400 }}` },
    }),
    boolIf('First delivery?', [1320, -100], '$json.created'),
    codeNode('Triage prompt', [1540, -100],
      code('triage-prompt').replace('__PROMPT_TEMPLATE__', promptTemplate).replace('__FAQ__', faq)),
    node('Ask LLM', 'n8n-nodes-base.executeWorkflow', 1.2, [1760, -100], {
      source: 'database',
      workflowId: { __rl: true, value: LLM_WORKFLOW_ID, mode: 'id' },
      options: { waitForSubWorkflow: true },
      // awaria modelu nie może zgubić wiadomości: Validate zrobi z niej pusty wynik, a baza skieruje ją do intake
    }, { onError: 'continueRegularOutput' }),
    codeNode('Triage validate', [1980, -100], code('triage-validate')),
    rpc('Complete', [2200, -100], 'triage_complete', `{ p_inbox_id: $json.inbox_id, p: $json.p }`),
    boolIf('To intake?', [2420, -100], `$json.route === 'intake'`),
    rpc('Forward data', [2640, -160], 'inbox_forward_data', `{ p_inbox_id: $json.inbox_id }`),

    // naprawa: wiadomości, które powinny trafić do intake, a nie trafiły (awaria po klasyfikacji albo przed nią)
    node('Schedule 5 min', 'n8n-nodes-base.scheduleTrigger', 1.2, [0, 520], {
      rule: { interval: [{ field: 'minutes', minutesInterval: 5 }] },
    }),
    node('Webhook sweep', 'n8n-nodes-base.webhook', 2.1, [0, 700], {
      httpMethod: 'POST', path: 'triage-sweep', responseMode: 'responseNode', options: {},
    }, { webhookId: 'inbox-triage-sweep-0001' }),
    configNode([220, 600], 'Config sweep'),
    codeNode('Sweep params', [440, 600], code('triage-sweep-params')),
    boolIf('Sweep allowed?', [660, 600], '$json.allowed'),
    node('Sweep forbidden', 'n8n-nodes-base.respondToWebhook', 1.1, [880, 760], {
      respondWith: 'json', responseBody: `={{ { error: 'FORBIDDEN' } }}`, options: { responseCode: 403 },
    }),
    boolIf('Sweep via webhook?', [880, 560], '$json.viaWebhook'),
    node('Sweep started', 'n8n-nodes-base.respondToWebhook', 1.1, [1100, 480], {
      respondWith: 'json', responseBody: `={{ { status: 'started' } }}`, options: { responseCode: 200 },
    }),
    rpc('Unforwarded', [1320, 560], 'inbox_unforwarded', '{}'),

    // wspólny koniec: przekazanie do workflow 01
    codeNode('Forward prep', [2860, 200], code('triage-forward-prep')),
    node('Forward to intake', 'n8n-nodes-base.httpRequest', 4.2, [3080, 200], {
      method: 'POST',
      url: `={{ $json.url }}`,
      sendHeaders: true,
      headerParameters: { parameters: [
        { name: 'Content-Type', value: 'application/json' },
        // sekret i atrapa idą wprost z wyrażeń, żeby nie trafiały do danych wykonania
        { name: 'X-Intake-Token', value: `={{ $env.INTAKE_TOKEN || '' }}` },
        { name: 'X-LLM-Mock', value: `={{ $json.mock }}` },
      ] },
      sendBody: true, contentType: 'json', specifyBody: 'json', jsonBody: `={{ JSON.stringify($json.payload) }}`,
      options: { timeout: 20000 },
    }, { onError: 'continueRegularOutput' }),
    boolIf('Forwarded?', [3300, 200], `['processing', 'duplicate'].includes($json.status)`),
    rpc('Mark forwarded', [3520, 140], 'triage_mark_forwarded', `{ p_inbox_id: $('Forward prep').item.json.inbox_id }`,
      { onError: 'continueRegularOutput' }, { response: { response: { responseFormat: 'text' } } }),
  ];

  return workflow(TRIAGE_WORKFLOW_ID, '11 Inbox triage', nodes, [
    ['Webhook', 'Config'], ['Config', 'Triage normalize'], ['Triage normalize', 'Valid input?'],
    ['Valid input?', 'Receive', 0], ['Valid input?', 'Rejected', 1],
    ['Receive', 'Accepted'], ['Accepted', 'First delivery?'], ['First delivery?', 'Triage prompt', 0],
    ['Triage prompt', 'Ask LLM'], ['Ask LLM', 'Triage validate'], ['Triage validate', 'Complete'],
    ['Complete', 'To intake?'], ['To intake?', 'Forward data', 0], ['Forward data', 'Forward prep'],

    ['Schedule 5 min', 'Config sweep'], ['Webhook sweep', 'Config sweep'], ['Config sweep', 'Sweep params'],
    ['Sweep params', 'Sweep allowed?'], ['Sweep allowed?', 'Sweep via webhook?', 0], ['Sweep allowed?', 'Sweep forbidden', 1],
    ['Sweep via webhook?', 'Sweep started', 0], ['Sweep via webhook?', 'Unforwarded', 1], ['Sweep started', 'Unforwarded'],
    ['Unforwarded', 'Forward prep'],

    ['Forward prep', 'Forward to intake'], ['Forward to intake', 'Forwarded?'], ['Forwarded?', 'Mark forwarded', 0],
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
  ['06-calculator.json', buildCalculator()],
  ['07-weekly-report.json', buildReport()],
  ['08-purchase-orders.json', buildPurchasing()],
  ['09-quote-followup.json', buildFollowup()],
  ['11-inbox-triage.json', buildTriage()],
]) {
  writeFileSync(join(outDir, file), JSON.stringify(wf, null, 2) + '\n');
  console.log(`zapisano n8n/workflows/${file} (${wf.nodes.length} węzłów)`);
}
