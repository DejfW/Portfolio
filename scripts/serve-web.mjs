#!/usr/bin/env node
// Serwuje web/ na http://localhost:8080: kalkulator (/), tablet salonowy (/showroom.html?salon=<kod>#<token>) i status zamówienia (/status.html?token=<token>).
// Strony wywołują API n8n na localhost:5678 przez CORS.
// Użycie: node scripts/serve-web.mjs [port]
import { createServer } from 'node:http';
import { readFileSync, existsSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { isPublicKey } from './lib/public-key.mjs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const port = Number(process.argv[2] || 8080);
const webDir = join(dirname(fileURLToPath(import.meta.url)), '..', 'web');
const pages = { '/': 'index.html', '/index.html': 'index.html', '/showroom.html': 'showroom.html', '/status.html': 'status.html' };

// Strona statusu woła Supabase REST kluczem publicznym (rola anon). Adres i klucz bierzemy ze zmiennych środowiska
// (SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, np. dla projektu w chmurze) albo z lokalnego `supabase status`;
// nie leżą w repozytorium. Klucz publiczny trafia do strony z założenia, ale nie dajemy tam klucza service_role.
// WEB_TARGET=cloud: projekt chmurowy z .env.local (SUPABASE_CLOUD_REF i SUPABASE_CLOUD_PUBLISHABLE_KEY; czytamy tylko te dwa
// klucze, żadnych sekretów). Klucz publiczny i tak przechodzi sprawdzenie isPublicKey.
function envFileValue(name) {
  const file = join(dirname(fileURLToPath(import.meta.url)), '..', '.env.local');
  if (!existsSync(file)) return undefined;
  const m = readFileSync(file, 'utf8').match(new RegExp(`^${name}=(['"]?)(.*)\\1$`, 'm'));
  return m ? m[2] : undefined;
}

function supabasePublic() {
  if (process.env.WEB_TARGET === 'cloud') {
    const ref = envFileValue('SUPABASE_CLOUD_REF'), key = envFileValue('SUPABASE_CLOUD_PUBLISHABLE_KEY');
    return { url: ref ? `https://${ref}.supabase.co` : undefined, key };
  }
  let url = process.env.SUPABASE_URL, key = process.env.SUPABASE_PUBLISHABLE_KEY;
  if (!url || !key) {
    try {
      const env = execFileSync('supabase', ['status', '-o', 'env'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
      const get = (n) => (env.match(new RegExp(`^${n}="(.*)"$`, 'm')) || [])[1];
      url = url || get('API_URL'); key = key || get('ANON_KEY');
    } catch (e) { /* brak lokalnego Supabase */ }
  }
  return { url, key };
}
createServer((req, res) => {
  const path = (req.url || '/').split('?')[0];
  const file = pages[path];
  if (req.method !== 'GET' || !file) { res.writeHead(404).end('Not found'); return; }
  let html = readFileSync(join(webDir, file), 'utf8');
  let connect = 'http://localhost:5678';
  if (file === 'status.html') {
    const { url, key } = supabasePublic();
    if (key && !isPublicKey(key)) { res.writeHead(503, { 'Content-Type': 'text/plain; charset=utf-8' }).end('Odmowa: do strony publicznej można wstawić tylko klucz publiczny (sb_publishable_... albo JWT z rolą anon), nigdy sekretny ani service_role.'); return; }
    if (!url || !key) { res.writeHead(503, { 'Content-Type': 'text/plain; charset=utf-8' }).end('Brak adresu Supabase: ustaw SUPABASE_URL i SUPABASE_PUBLISHABLE_KEY albo uruchom supabase start.'); return; }
    html = html.replace('__SUPABASE_URL__', JSON.stringify(url)).replace('__SUPABASE_KEY__', JSON.stringify(key));
    connect = new URL(url).origin;
  }
  res.writeHead(200, {
    'Content-Type': 'text/html; charset=utf-8', 'X-Content-Type-Options': 'nosniff', 'X-Frame-Options': 'DENY',
    'Referrer-Policy': 'no-referrer',
    'Content-Security-Policy': `default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src ${connect}; base-uri 'none'; form-action 'none'`,
  });
  res.end(html);
}).listen(port, '127.0.0.1', () => console.log(`Kalkulator: http://localhost:${port}, salon: http://localhost:${port}/showroom.html?salon=<kod>#<token>`));
