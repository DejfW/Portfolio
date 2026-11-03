// Klucz wstawiany do publicznej strony musi być kluczem publicznym: nowy `sb_publishable_...` albo dawny JWT z rolą `anon`.
// Klucze `sb_secret_...` i JWT z rolą service_role (albo inną) odrzucamy, bo pozwalają ominąć RLS.
export function isPublicKey(key) {
  if (typeof key !== 'string' || !key) return false;
  if (key.startsWith('sb_publishable_')) return /^sb_publishable_[A-Za-z0-9_-]+$/.test(key);
  const parts = key.split('.');
  if (parts.length !== 3) return false;
  try {
    const payload = JSON.parse(Buffer.from(parts[1], 'base64url').toString('utf8'));
    return payload && payload.role === 'anon';
  } catch (e) {
    return false;
  }
}
