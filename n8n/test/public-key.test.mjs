import test from 'node:test';
import assert from 'node:assert/strict';
import { isPublicKey } from '../../scripts/lib/public-key.mjs';

const jwt = (role) => `h.${Buffer.from(JSON.stringify({ role })).toString('base64url')}.s`;

test('klucz publiczny: sb_publishable i JWT z rolą anon przechodzą', () => {
  assert.equal(isPublicKey('sb_publishable_AbC123_-x'), true);
  assert.equal(isPublicKey(jwt('anon')), true);
});

test('klucz publiczny: service_role, sekretne i śmieci są odrzucane (rola siedzi w payloadzie JWT, nie jako jawny tekst)', () => {
  for (const bad of [jwt('service_role'), jwt('authenticated'), jwt(undefined), 'sb_secret_abc', 'sb_publishable_', 'sb_publishable_a b',
    'a.b.c', 'h.%%%.s', '', null, undefined, 42, 'eyJ.eyJ']) {
    assert.equal(isPublicKey(bad), false, String(bad));
  }
});
