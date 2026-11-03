// Prosty odbiornik HTTP do testów dostarczania: zapisuje treść każdego POST do pliku i odpowiada "ok",
// a dla wiadomości zawierających SINKFAIL odpowiada błędem 500. Użycie: node http-sink.mjs <plik_portu> <plik_logu>
import http from 'node:http';
import { writeFileSync, appendFileSync } from 'node:fs';

const [portFile, logFile] = process.argv.slice(2);
const server = http.createServer((req, res) => {
  let body = '';
  req.on('data', (c) => { body += c; });
  req.on('end', () => {
    let text = '';
    try { text = JSON.parse(body).text || ''; } catch (e) { /* ignorujemy */ }
    appendFileSync(logFile, JSON.stringify({ method: req.method, url: req.url, text }) + '\n');
    if (text.includes('SINKFAIL')) { res.writeHead(500); res.end('boom'); } else { res.writeHead(200); res.end('ok'); }
  });
});
server.listen(0, '127.0.0.1', () => writeFileSync(portFile, String(server.address().port)));
