#!/usr/bin/env node
// Serwer statycznego portfolio (portfolio/) na http://localhost:8090.
// Użycie: node scripts/serve-portfolio.mjs [port]
import { createServer } from 'node:http';
import { statSync, createReadStream } from 'node:fs';
import { resolve, join, extname, sep, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const MIME = {
  '.html': 'text/html; charset=utf-8', '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8', '.mjs': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8', '.svg': 'image/svg+xml',
  '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.webp': 'image/webp',
  '.gif': 'image/gif', '.mp4': 'video/mp4', '.webm': 'video/webm', '.pdf': 'application/pdf',
  '.txt': 'text/plain; charset=utf-8',
};

const CSP = [
  "default-src 'self'", "script-src 'self'", "style-src 'self' https://fonts.googleapis.com",
  'font-src https://fonts.gstatic.com', "img-src 'self' data:", "media-src 'self'",
  "base-uri 'none'", "form-action 'none'", "frame-ancestors 'none'",
].join('; ');

export function createPortfolioServer(rootDir) {
  const root = resolve(rootDir);
  const send = (res, status, body = '', extra = {}) => {
    res.writeHead(status, { 'Content-Type': 'text/plain; charset=utf-8', ...extra });
    res.end(body);
  };

  return createServer((req, res) => {
    if (req.method !== 'GET' && req.method !== 'HEAD') return send(res, 405, 'Method not allowed', { Allow: 'GET, HEAD' });

    let pathname;
    try { pathname = decodeURIComponent((req.url || '/').split('?')[0].split('#')[0]); } catch { return send(res, 400, 'Bad request'); }
    if (pathname.includes('\0') || pathname.includes('\\')) return send(res, 400, 'Bad request');
    if (pathname.split('/').some((seg) => seg.startsWith('.'))) return send(res, 404, 'Not found');

    let file = resolve(join(root, pathname));
    if (file !== root && !file.startsWith(root + sep)) return send(res, 404, 'Not found');
    let st;
    try {
      st = statSync(file);
      if (st.isDirectory()) { file = join(file, 'index.html'); st = statSync(file); }
    } catch { return send(res, 404, 'Not found'); }
    if (!st.isFile()) return send(res, 404, 'Not found');

    const headers = {
      'Content-Type': MIME[extname(file).toLowerCase()] || 'application/octet-stream',
      'X-Content-Type-Options': 'nosniff', 'Content-Security-Policy': CSP,
      'Referrer-Policy': 'no-referrer', 'Cache-Control': 'no-cache', 'Accept-Ranges': 'bytes',
    };
    let start = 0, end = st.size - 1, status = 200;
    const range = req.headers.range;
    if (range) {
      const m = /^bytes=(\d*)-(\d*)$/.exec(range);
      if (!m || (m[1] === '' && m[2] === '')) return send(res, 416, 'Range not satisfiable', { 'Content-Range': `bytes */${st.size}` });
      if (m[1] === '') { start = Math.max(0, st.size - Number(m[2])); }
      else { start = Number(m[1]); if (m[2] !== '') end = Math.min(end, Number(m[2])); }
      if (start > end || start >= st.size) return send(res, 416, 'Range not satisfiable', { 'Content-Range': `bytes */${st.size}` });
      status = 206;
      headers['Content-Range'] = `bytes ${start}-${end}/${st.size}`;
    }
    headers['Content-Length'] = end - start + 1;
    res.writeHead(status, headers);
    if (req.method === 'HEAD') return res.end();
    createReadStream(file, { start, end }).pipe(res);
  });
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const port = Number(process.argv[2] || 8090);
  const root = join(dirname(fileURLToPath(import.meta.url)), '..', 'portfolio');
  createPortfolioServer(root).listen(port, () => console.log(`Portfolio: http://localhost:${port}`));
}
