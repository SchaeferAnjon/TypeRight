// Collects every t(zh, en) pair of website/index.html: literal pairs from the source, plus the
// evaluated ones seen while clicking through every page in English. Writes pairs.json; saves icon.svg and preview.png.
const fs = require('fs');
const { chromium } = require('/opt/homebrew/lib/node_modules/playwright');
const site = process.argv[2], out = process.argv[3];
const src = fs.readFileSync(site + '/index.html', 'utf8');
const pairs = new Map();
function readLit(i) { // JS string literal starting at i -> [value, endIndex] or null
  const q = src[i]; if (!`'"\``.includes(q)) return null;
  let j = i + 1;
  while (j < src.length && src[j] !== q) { if (src[j] === '\\') j++; if (q === '`' && src[j] === '$' && src[j + 1] === '{') return null; j++; }
  return [Function('return ' + src.slice(i, j + 1))(), j + 1];
}
const re = /(^|[^\w$.])t\(/g; let m;
while ((m = re.exec(src))) {
  let i = m.index + m[0].length; const a = readLit(i); if (!a) continue;
  i = a[1]; while (src[i] === ' ') i++; if (src[i] !== ',') continue; i++; while (src[i] === ' ') i++;
  const b = readLit(i); if (!b) continue; pairs.set(a[0], b[0]);
}
const staticCount = pairs.size;
(async () => {
  const br = await chromium.launch({ channel: 'chrome' });
  const pg = await br.newPage({ viewport: { width: 1440, height: 900 } });
  await pg.exposeFunction('__push', (zh, en) => { if (typeof zh === 'string' && en != null && !pairs.has(zh)) pairs.set(zh, en); });
  await pg.addInitScript(() => { window.__collect = (zh, en) => window.__push(zh, en); });
  for (const page of ['home', 'pricing', 'guide', 'privacy', 'refund', 'terms']) {
    await pg.goto(`file://${site}/index.html#page=${page}&lang=en`); await pg.reload(); await pg.waitForTimeout(page === 'home' ? 26000 : 800);
    for (const sel of ['#persona button', '[data-cur]', '[data-per]', '.seg button', 'details summary']) {
      for (const el of await pg.$$(sel)) { try { await el.click({ timeout: 500 }); await pg.waitForTimeout(80); } catch (e) {} }
    }
  }
  await pg.goto(`file://${site}/index.html#lang=zh`); await pg.reload(); await pg.waitForTimeout(800);
  fs.writeFileSync(site + '/icon.svg', await pg.evaluate(() => APPICON(64).replace('<svg ', '<svg xmlns="http://www.w3.org/2000/svg" ')));
  const og = await br.newPage({ viewport: { width: 1200, height: 630 } });
  await og.goto(`file://${site}/index.html#lang=zh&theme=light`); await og.waitForTimeout(3000);
  await og.screenshot({ path: site + '/preview.png' });
  fs.writeFileSync(out, JSON.stringify(Object.fromEntries(pairs), null, 1));
  console.log('static', staticCount, 'total', pairs.size);
  await br.close();
})();
