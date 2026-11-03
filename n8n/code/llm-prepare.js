// Sub-workflow 00-llm: koduje prompt w base64, więc do powłoki trafiają wyłącznie znaki [A-Za-z0-9+/=].
const i = $input.first().json;
const mock = i.mock || '';
if (!/^[a-z0-9-]*$/.test(mock)) throw new Error('INVALID_MOCK_NAME');
if (typeof i.prompt !== 'string' || !i.prompt) throw new Error('EMPTY_PROMPT');
// Ścieżka projektu pochodzi z konfiguracji n8n, ale i tak odrzucamy znaki specjalne powłoki w cudzysłowie.
if (typeof i.projectDir !== 'string' || !i.projectDir || /["`$\\]/.test(i.projectDir)) {
  throw new Error('INVALID_PROJECT_DIR');
}
const b64 = Buffer.from(i.prompt, 'utf8').toString('base64');
// Prompt idzie w argumencie polecenia, a system ogranicza jego długość (ARG_MAX ok. 1 MB).
// Zbyt duży prompt (np. ogromny katalog) kończy wykonanie błędem, a zgłoszenie trafia
// do ręcznego sprawdzenia przez mark_stuck_intakes.
if (b64.length > 500000) throw new Error('PROMPT_TOO_LARGE');
return [{
  json: {
    b64,
    mock,
    projectDir: i.projectDir,
    // opcjonalny znacznik wywołującego; wraca w wyniku, żeby wyniki dało się dopasować bez polegania na kolejności
    ref: typeof i.ref === 'string' ? i.ref.slice(0, 100) : null,
  },
}];
