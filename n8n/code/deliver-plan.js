// Decyduje, co zrobić z każdą oczekującą wiadomością: wysłać (route "slack:send" / "email:send") albo
// zostawić w kolejce ("skip"). Maile trafiają tylko na adresy z listy dozwolonych (pełny adres albo "@domena"),
// więc przypadkowy adres z danych demo nigdy nie dostanie prawdziwej wiadomości.
const p = $('Deliver params').first().json;
const entries = p.allowlist.split(',').map((s) => s.trim().toLowerCase()).filter(Boolean);
const allowedAddress = (to) => {
  const t = String(to || '').trim().toLowerCase();
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(t)) return false;
  return entries.some((e) => (e.startsWith('@') ? t.endsWith(e) : t === e));
};

return $input.all().map(({ json: m }) => {
  let route = 'skip';
  let reason = null;
  if (m.channel === 'slack') {
    if (p.slackReady) route = 'slack:send'; else reason = 'NO_SLACK_URL';
  } else if (m.channel === 'email') {
    if (!p.emailOn) reason = 'EMAIL_DELIVERY_OFF';
    else if (!allowedAddress(m.to)) reason = 'ADDRESS_NOT_ALLOWED';
    else route = 'email:send';
  } else reason = 'UNKNOWN_CHANNEL';
  return { json: { ...m, route, reason } };
});
