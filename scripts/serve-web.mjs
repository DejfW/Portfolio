#!/usr/bin/env node
// Serwuje web/ na http://localhost:8080: kalkulator (/) i tablet salonowy (/showroom.html?salon=<kod>#<token>).
// Strony wywołują API n8n na localhost:5678 przez CORS.
// Użycie: node scripts/serve-web.mjs [port]
import { createServer } from 'node:http';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const port = Number(process.argv[2] || 8080);
const webDir = join(dirname(fileURLToPath(import.meta.url)), '..', 'web');
const pages = { '/': 'index.html', '/index.html': 'index.html', '/showroom.html': 'showroom.html' };
createServer((req, res) => {
  const path = (req.url || '/').split('?')[0];
  const file = pages[path];
  if (req.method !== 'GET' || !file) { res.writeHead(404).end('Not found'); return; }
  res.writeHead(200, {
    'Content-Type': 'text/html; charset=utf-8', 'X-Content-Type-Options': 'nosniff', 'X-Frame-Options': 'DENY',
    'Referrer-Policy': 'no-referrer',
    'Content-Security-Policy': "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src http://localhost:5678; base-uri 'none'; form-action 'none'",
  });
  res.end(readFileSync(join(webDir, file)));
}).listen(port, '127.0.0.1', () => console.log(`Kalkulator: http://localhost:${port}, salon: http://localhost:${port}/showroom.html?salon=<kod>#<token>`));
