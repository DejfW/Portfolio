// Wspólne pomocniki stron HTML i komunikatów (wstawiane do węzłów Code przez n8n/build.mjs).
const esc = (s) => String(s === undefined || s === null ? '' : s).replace(/[&<>"']/g, (c) => (
  { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const slackEsc = (s) => String(s === undefined || s === null ? '' : s).replace(/[&<>]/g, (c) => (
  { '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]));
const page = (title, body, code = 200) => ({
  code,
  html: `<!doctype html><html lang="pl"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">` +
    `<title>${esc(title)}</title><style>body{font-family:system-ui,sans-serif;max-width:34rem;margin:2rem auto;padding:0 1rem;color:#1a1a1a}` +
    `h1{font-size:1.3rem}button{font:inherit;padding:.6rem 1.2rem;border:0;border-radius:.4rem;background:#1f6feb;color:#fff;cursor:pointer}` +
    `select,input{font:inherit;padding:.5rem;width:100%;box-sizing:border-box;margin:.3rem 0 1rem}.err{color:#b42318}.ok{color:#067647}li{margin:.25rem 0}</style>` +
    `</head><body>${body}</body></html>`,
});
const pln = (x) => `${Number(x).toFixed(2).replace('.', ',')} zł`;
const isUuid = (s) => typeof s === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(s);
