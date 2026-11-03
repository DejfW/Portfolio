// Sub-workflow 00-llm: niepowodzenie modelu (timeout, błąd agy) daje pusty tekst,
// a nie przerwanie całego przepływu; walidacja po stronie wywołującego zrobi z tego needs_review.
const r = $input.first().json;
const failed = !!r.error || (r.exitCode !== undefined && r.exitCode !== 0);
const text = !failed && typeof r.stdout === 'string' ? r.stdout : '';
return [{
  json: {
    text,
    ok: text !== '',
    error: failed ? String(r.error || r.stderr || `exit ${r.exitCode}`).slice(0, 300) : null,
  },
}];
