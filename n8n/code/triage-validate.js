// Wstępna walidacja odpowiedzi AI: wyciągamy z niej JSON (także z bloku kodu) i przepuszczamy tylko pola o oczekiwanych typach.
// Wszystko inne (śmieci, odmowa, brak odpowiedzi) daje pusty obiekt, a baza (triage_complete) skieruje taką wiadomość do intake.
const text = String($input.first().json.text || '').trim();
const inboxId = $('Receive').first().json.inbox_id;
let p = {};
try {
  const m = text.match(/\{[\s\S]*\}/);
  const o = m ? JSON.parse(m[0]) : null;
  if (o && typeof o === 'object' && !Array.isArray(o)) {
    if (typeof o.category === 'string') p.category = o.category.slice(0, 20);
    if (typeof o.confidence === 'number' && Number.isFinite(o.confidence)) p.confidence = o.confidence;
    if (typeof o.reply_draft === 'string') p.reply_draft = o.reply_draft.slice(0, 3000);
  }
} catch (e) { p = {}; }
return [{ json: { inbox_id: inboxId, p } }];
