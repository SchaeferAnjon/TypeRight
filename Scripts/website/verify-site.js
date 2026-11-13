// Opens the website the way visitors do and checks it, then clicks through the parts that react.
//   matrix: 6 pages × 9 languages × 1280 and 390 wide × light and dark. Each one: no missing translation (MISSING in the page),
//           no Chinese left on non-Chinese pages (the demo's typed words and native language names excepted), no {0} or
//           undefined in the text, no console error, no failed local request, no horizontal scrolling. A screenshot of each.
//   flows:  language menu, remembered language, browser language, page change and reload, back button, redirect pages,
//           download button with and without a GitHub release, price toggles, "pick one", the try-it-yourself demo, theme.
// GitHub's API is answered locally (no request leaves this Mac); any other outside request fails the run.
// Usage: NODE_PATH=$(npm root -g) node Scripts/website/verify-site.js http://127.0.0.1:8737/website/ <screenshot folder> [--quick]
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');

const [base, shots] = process.argv.slice(2);
const quick = process.argv.includes('--quick');
if (!base || !shots) throw new Error('usage: verify-site.js <site url ending in /> <screenshot folder> [--quick]');
fs.mkdirSync(shots, { recursive: true });

const LANGS = quick ? ['zh', 'en'] : ['zh', 'zh-Hant', 'en', 'ja', 'ko', 'de', 'fr', 'es', 'it'];
const PAGES = ['home', 'pricing', 'guide', 'privacy', 'refund', 'terms'];
const WIDTHS = [1280, 390];
const SCHEMES = ['light', 'dark'];
const ALLOWED_HAN = /预约|会议|周末|发票|提醒|推迟|截止日期|报销|简体中文|繁體中文|日本語/g;

const RELEASE = [{ draft: false, prerelease: false, tag_name: 'v0.1.0', published_at: '2026-11-20T10:00:00Z', html_url: 'https://github.com/SchaeferAnjon/TypeRight/releases/tag/v0.1.0',
  assets: [{ name: 'TypeRight-0.1.0-Universal.dmg', size: 31457280, browser_download_url: 'https://github.com/SchaeferAnjon/TypeRight/releases/download/v0.1.0/TypeRight-0.1.0-Universal.dmg' }] }];
const GITHUB = { none: { status: 200, body: '[]' }, missing: { status: 404, body: '{"message":"Not Found"}' }, ready: { status: 200, body: JSON.stringify(RELEASE) }, down: null };

const problems = [];
const fail = (where, what) => { problems.push(`${where}: ${what}`); };
let browser;

async function context(opts = {}, github = 'none') {
  const ctx = await browser.newContext({ viewport: { width: opts.width || 1280, height: opts.height || 860 }, colorScheme: opts.scheme || 'light', locale: opts.locale || 'zh-CN', acceptDownloads: true });
  const outside = [];
  await ctx.route(/^https?:\/\//, (route) => {
    const url = route.request().url();
    if (url.startsWith(base.replace(/\/website\/$/, '/'))) return route.continue();
    if (url.startsWith('https://api.github.com/repos/SchaeferAnjon/TypeRight/releases')) {
      const g = GITHUB[github];
      return g ? route.fulfill({ status: g.status, contentType: 'application/json', body: g.body }) : route.abort('internetdisconnected');
    }
    if (url.startsWith('https://github.com/SchaeferAnjon/TypeRight/releases/download/')) {
      return route.fulfill({ status: 200, headers: { 'content-type': 'application/x-apple-diskimage', 'content-disposition': 'attachment; filename="TypeRight-0.1.0-Universal.dmg"' }, body: 'dmg' });
    }
    outside.push(url);
    return route.abort('blockedbyclient');
  });
  return { ctx, outside };
}
// expected: a console error the scenario causes on purpose (GitHub answering 404, or not reachable at all)
function watch(page, where, expected = null) {
  page.on('console', (m) => { if (m.type() === 'error' && !(expected && expected.test(m.text()))) fail(where, 'console error: ' + m.text().slice(0, 160)); });
  page.on('pageerror', (e) => fail(where, 'page error: ' + e.message.slice(0, 160)));
  page.on('response', (r) => { if (r.status() >= 400 && r.url().startsWith(base)) fail(where, `HTTP ${r.status()} ${r.url()}`); });
}

async function checkPage(page, where, lang) {
  const r = await page.evaluate(() => {
    const text = document.body.innerText + '\n' + document.title + '\n' + document.querySelector('meta[name="description"]').content + '\n'
      + [...document.querySelectorAll('[title],[aria-label],[alt]')].map((e) => [e.title, e.getAttribute('aria-label'), e.getAttribute('alt')].filter(Boolean).join(' ')).join(' ');
    let wide = null;
    if (document.documentElement.scrollWidth > innerWidth + 1) {
      wide = [...document.querySelectorAll('body *')].filter((e) => e.getBoundingClientRect().right > innerWidth + 1 && getComputedStyle(e).position !== 'fixed')
        .slice(0, 3).map((e) => `${e.tagName.toLowerCase()}.${[...e.classList].join('.')} right=${Math.round(e.getBoundingClientRect().right)}`);
    }
    // tables that would need their own sideways scrolling
    const inner = [...document.querySelectorAll('.tblwrap')].filter((w) => w.scrollWidth > w.clientWidth + 1).length;
    return { missing: [...MISSING], text, inner, scrollW: document.documentElement.scrollWidth, wide, lang: document.documentElement.lang, theme: document.documentElement.dataset.theme, bg: getComputedStyle(document.body).backgroundColor };
  });
  if (r.missing.length) fail(where, `${r.missing.length} untranslated: ${r.missing.slice(0, 3).join(' | ').slice(0, 160)}`);
  const leftover = r.text.match(/\{\d\}|\bundefined\b|\bNaN\b|\[object Object\]/);
  if (leftover) fail(where, 'raw text on page: ' + leftover[0]);
  if (lang !== 'zh' && lang !== 'zh-Hant' && lang !== 'ja') {
    const han = r.text.replace(ALLOWED_HAN, '').match(/.{0,20}[㐀-鿿].{0,20}/);
    if (han) fail(where, 'Chinese left: ' + han[0].replace(/\n/g, ' '));
  }
  if (r.wide) fail(where, `horizontal scroll (${r.scrollW}px): ${r.wide.join(', ')}`);
  if (r.inner) fail(where, `${r.inner} table(s) scroll sideways`);
  return r;
}

async function matrix() {
  let n = 0;
  for (const scheme of SCHEMES) for (const width of WIDTHS) {
    const { ctx, outside } = await context({ width, scheme });
    for (const lang of LANGS) for (const pg of PAGES) {
      const where = `${pg} ${lang} ${width} ${scheme}`;
      const page = await ctx.newPage();
      watch(page, where);
      await page.goto(`${base}index.html?lang=${lang}${pg === 'home' ? '' : '#page=' + pg}`);
      await page.waitForTimeout(pg === 'home' ? 1400 : 350);
      const r = await checkPage(page, where, lang);
      if (r.theme !== scheme) fail(where, `theme is ${r.theme}`);
      if (r.lang !== ({ zh: 'zh-CN', 'zh-Hant': 'zh-TW' }[lang] || lang)) fail(where, `html lang is ${r.lang}`);
      await page.screenshot({ path: path.join(shots, `${pg}-${lang}-${width}-${scheme}.png`), fullPage: (lang === 'zh' || lang === 'en') && scheme === 'light' });
      await page.close();
      n++;
    }
    if (outside.length) fail(`matrix ${width} ${scheme}`, 'outside requests: ' + [...new Set(outside)].join(', '));
    await ctx.close();
  }
  return n;
}

async function flows() {
  const done = [];
  const step = async (name, fn) => { const before = problems.length; try { await fn(); } catch (e) { fail(name, e.message.split('\n')[0].slice(0, 200)); } done.push(`${problems.length === before ? 'ok ' : 'BAD'} ${name}`); };

  // language menu: pick, the page reloads in that language, the choice is remembered without ?lang
  await step('language menu switches and is remembered', async () => {
    const { ctx } = await context();
    const page = await ctx.newPage(); watch(page, 'lang menu');
    await page.goto(base + 'index.html#page=pricing');
    if (await page.evaluate(() => document.documentElement.lang) !== 'zh-CN') throw new Error('did not start in zh-CN');
    await page.click('#lbtn');
    if (!await page.isVisible('#lpop')) throw new Error('menu did not open');
    await page.keyboard.press('Escape');
    if (await page.isVisible('#lpop')) throw new Error('Esc did not close the menu');
    await page.click('#lbtn');
    await Promise.all([page.waitForNavigation(), page.click('#lpop [data-lang="de"]')]);
    const s = await page.evaluate(() => ({ lang: document.documentElement.lang, btn: document.querySelector('#lbtn span').textContent, page: location.hash, h: document.querySelector('.h2').textContent, saved: localStorage.getItem('tr.lang') }));
    if (s.lang !== 'de' || s.btn !== 'Deutsch' || s.saved !== 'de') throw new Error('after picking: ' + JSON.stringify(s));
    if (!s.page.includes('page=pricing')) throw new Error('page lost after switching language: ' + s.page);
    await page.goto(base + 'index.html');
    if (await page.evaluate(() => document.documentElement.lang) !== 'de') throw new Error('choice not remembered on a plain visit');
    await page.screenshot({ path: path.join(shots, 'flow-language-remembered-de.png') });
    await ctx.close();
  });
  // browser language decides when nothing was picked
  await step('browser language is used on a first visit', async () => {
    for (const [locale, want] of [['ja-JP', 'ja'], ['zh-TW', 'zh-TW'], ['zh-HK', 'zh-TW'], ['fr-CA', 'fr'], ['ko-KR', 'ko'], ['es-MX', 'es'], ['it-IT', 'it'], ['de-AT', 'de'], ['pt-BR', 'en'], ['en-GB', 'en'], ['zh-CN', 'zh-CN']]) {
      const { ctx } = await context({ locale });
      const page = await ctx.newPage(); watch(page, 'browser ' + locale);
      await page.goto(base + 'index.html');
      const got = await page.evaluate(() => document.documentElement.lang);
      if (got !== want) throw new Error(`${locale} gave ${got}, wanted ${want}`);
      await ctx.close();
    }
  });
  // nav to a page, reload keeps it, back returns home; doc table of contents scrolls
  await step('page change survives reload, back works, contents scroll', async () => {
    const { ctx } = await context();
    const page = await ctx.newPage(); watch(page, 'pages');
    await page.goto(base + 'index.html?lang=en');
    await page.click('.snav .links a[data-go="pricing"]');
    if (!page.url().includes('#page=pricing')) throw new Error('hash not written: ' + page.url());
    await page.reload(); await page.waitForTimeout(300);
    if (!await page.isVisible('#persona')) throw new Error('reload did not stay on pricing');
    await page.goBack(); await page.waitForTimeout(300);
    if (!await page.isVisible('#hdemo')) throw new Error('back did not return home');
    await page.click('.foot a[data-go="privacy"]'); await page.waitForTimeout(300);
    // no free checks and no anonymous check-in any more (2026-11-13): the privacy page must not promise either
    const doc = await page.textContent('.doc');
    if (/first 100|free checks|check-in/i.test(doc)) throw new Error('privacy page still mentions free checks or the check-in');
    await page.click('.toc a[data-go="privacy#d10"]'); await page.waitForTimeout(900);
    const top = await page.evaluate(() => document.getElementById('d10').getBoundingClientRect().top);
    if (top < 0 || top > 200) throw new Error('contents link did not scroll to its section, top=' + top);
    await page.screenshot({ path: path.join(shots, 'flow-privacy-toc-en.png') });
    await ctx.close();
  });
  await step('redirect pages land on their page', async () => {
    const { ctx } = await context();
    const page = await ctx.newPage(); watch(page, 'redirects');
    for (const [file, sel] of [['pricing.html', '#persona'], ['guide.html', '.doc [data-part="拿 Key 步骤"]'], ['privacy.html', '.doc[data-part="隐私政策"]'], ['refund.html', '#d0'], ['terms.html', '#d6']]) {
      await page.goto(base + file); await page.waitForURL(/index\.html#page=|\/#page=/); await page.waitForTimeout(300);
      if (!await page.isVisible(sel)) throw new Error(`${file} did not show ${sel} (at ${page.url()})`);
    }
    await ctx.close();
  });
  // download: nothing released yet -> a calm sheet, no navigation, no dead link
  await step('download with no release yet', async () => {
    for (const g of ['none', 'missing']) {
      const { ctx } = await context({}, g);
      const page = await ctx.newPage(); watch(page, 'download ' + g, g === 'missing' ? /404/ : null);
      await page.goto(base + 'index.html?lang=zh'); await page.waitForTimeout(400);
      const url = page.url();
      await page.click('.bhero [data-dl]'); await page.waitForTimeout(300);
      const s = await page.evaluate(() => ({ text: document.getElementById('dlsheet').innerText, links: [...document.querySelectorAll('#dlsheet a')].map((a) => a.href), pages: 0 }));
      if (!s.text.includes('第一版还在路上')) throw new Error(g + ': sheet says ' + s.text.slice(0, 80));
      if (s.links.length) throw new Error(g + ': sheet links out: ' + s.links.join(' '));
      if (page.url() !== url || ctx.pages().length !== 1) throw new Error(g + ': navigated away');
      if (g === 'none') await page.screenshot({ path: path.join(shots, 'flow-download-no-release.png') });
      await page.click('#dlsheet [data-go="guide"]'); await page.waitForTimeout(300);
      if (!page.url().includes('page=guide') || await page.isVisible('#dlsheet')) throw new Error(g + ': guide button did not go to the guide');
      await ctx.close();
    }
  });
  await step('download with a release starts the .dmg and shows the version', async () => {
    const { ctx } = await context({}, 'ready');
    const page = await ctx.newPage(); watch(page, 'download ready');
    await page.goto(base + 'index.html?lang=en'); await page.waitForTimeout(500);
    const meta = await page.textContent('#verline');
    if (!meta.includes('v0.1.0')) throw new Error('hero has no version line: ' + meta);
    const [dl] = await Promise.all([page.waitForEvent('download'), page.click('.snav [data-dl]')]);
    if (!dl.url().endsWith('TypeRight-0.1.0-Universal.dmg')) throw new Error('downloaded ' + dl.url());
    const s = await page.textContent('#dlsheet');
    if (!/Downloading TypeRight/.test(s) || !/30 MB/.test(s)) throw new Error('sheet: ' + s.slice(0, 120));
    if (!(await page.textContent('#footver')).includes('v0.1.0')) throw new Error('footer has no version');
    await page.screenshot({ path: path.join(shots, 'flow-download-ready-en.png') });
    await ctx.close();
  });
  await step('download when GitHub cannot be reached', async () => {
    const { ctx } = await context({}, 'down');
    const page = await ctx.newPage(); watch(page, 'download down', /ERR_INTERNET_DISCONNECTED/);
    await page.goto(base + 'index.html?lang=fr'); await page.waitForTimeout(500);
    await page.click('.bhero [data-dl]'); await page.waitForTimeout(200);
    const href = await page.getAttribute('#dlsheet a.sbtn', 'href');
    if (href !== 'https://github.com/SchaeferAnjon/TypeRight/releases/latest') throw new Error('fallback link is ' + href);
    await page.mouse.click(5, 400); await page.waitForTimeout(100);
    if (await page.isVisible('#dlsheet')) throw new Error('click outside did not close the sheet');
    await ctx.close();
  });
  await step('price toggles and "pick one"', async () => {
    const { ctx } = await context();
    const page = await ctx.newPage(); watch(page, 'pricing');
    await page.goto(base + 'index.html?lang=zh#page=pricing');
    const pr = () => page.textContent('#board .mem .pr');
    if (!(await pr()).startsWith('¥9.9')) throw new Error('default price ' + await pr());
    await page.click('[data-cyc="y"]'); if (!(await pr()).startsWith('¥99')) throw new Error('yearly CNY ' + await pr());
    await page.click('[data-cur="usd"]'); if (!(await pr()).startsWith('$19.90')) throw new Error('yearly USD ' + await pr());
    await page.click('[data-cyc="m"]'); if (!(await pr()).startsWith('$1.99')) throw new Error('monthly USD ' + await pr());
    await page.click('#persona button[data-p="key"]'); await page.waitForTimeout(500);
    if (!await page.$('#board .col.pick[data-plan="key"]')) throw new Error('"pick one" did not light the own-key column');
    await page.screenshot({ path: path.join(shots, 'flow-pricing-pick-key.png') });
    const { ctx: c2 } = await context({ locale: 'en-US' });
    const p2 = await c2.newPage(); await p2.goto(base + 'index.html#page=pricing');
    if (!(await p2.textContent('#board .mem .pr')).startsWith('$1.99')) throw new Error('English visitors should start in USD');
    await c2.close(); await ctx.close();
  });
  await step('try it yourself: typo, Tab, sentence, Esc', async () => {
    const { ctx } = await context();
    const page = await ctx.newPage(); watch(page, 'try');
    await page.goto(base + 'index.html?lang=zh'); await page.waitForTimeout(600);
    await page.click('#tgo');
    await page.keyboard.type('See you tomorow ', { delay: 30 });
    await page.waitForSelector('#hdemo .pa-card', { timeout: 3000 });
    if (!(await page.textContent('#hdemo .pa-card')).includes('tomorrow')) throw new Error('no spelling card');
    await page.screenshot({ path: path.join(shots, 'flow-try-spelling.png') });
    await page.keyboard.press('Tab'); await page.waitForTimeout(200);
    if (!(await page.textContent('#hdemo .field')).includes('See you tomorrow')) throw new Error('Tab did not fix: ' + await page.textContent('#hdemo .field'));
    await page.keyboard.type('. I has a question.', { delay: 30 });
    await page.waitForSelector('#hdemo .pa-card', { timeout: 4000 });
    if (!(await page.innerHTML('#hdemo .pa-card')).includes('have')) throw new Error('no sentence card');
    await page.keyboard.press('Escape'); await page.waitForTimeout(150);
    if (await page.$('#hdemo .pa-card')) throw new Error('Esc did not close the card');
    await page.keyboard.type(' I want to 预约', { delay: 40 }); await page.waitForTimeout(2600);
    if (!(await page.textContent('#hdemo .pa-card')).includes('book')) throw new Error('no Chinese card');
    await page.screenshot({ path: path.join(shots, 'flow-try-chinese.png') });
    await page.click('#tback'); await page.waitForTimeout(300);
    if (await page.$('#play.trying')) throw new Error('"watch the demo" did not leave typing mode');
    await ctx.close();
  });
  await step('dark theme follows the system, also live', async () => {
    const { ctx } = await context({ scheme: 'light' });
    const page = await ctx.newPage(); watch(page, 'theme');
    await page.goto(base + 'index.html?lang=en');
    const bg = () => page.evaluate(() => [document.documentElement.dataset.theme, getComputedStyle(document.body).backgroundColor]);
    const a = await bg(); await page.emulateMedia({ colorScheme: 'dark' }); await page.waitForTimeout(100); const b = await bg();
    if (a[0] !== 'light' || b[0] !== 'dark' || a[1] === b[1]) throw new Error(`light ${a} → dark ${b}`);
    await ctx.close();
  });
  await step('FAQ opens, footer family icons link out', async () => {
    const { ctx } = await context();
    const page = await ctx.newPage(); watch(page, 'faq');
    await page.goto(base + 'index.html?lang=ko'); await page.waitForTimeout(400);
    await page.click('#faq details:first-child summary');
    if (!await page.$eval('#faq details:first-child', (d) => d.open)) throw new Error('FAQ did not open');
    const fam = await page.$$eval('.fam .icons a', (as) => as.map((a) => a.getAttribute('href')));
    if (fam.length !== 4 || !fam.includes('https://getnewword.us-cloud.uk')) throw new Error('family links: ' + fam.join(' '));
    await ctx.close();
  });
  return done;
}

(async () => {
  browser = await chromium.launch({ executablePath: process.env.PW_CHROME || undefined });
  const t0 = Date.now();
  const n = await matrix();
  const done = await flows();
  await browser.close();
  console.log(`matrix: ${n} page loads (${PAGES.length} pages × ${LANGS.length} languages × ${WIDTHS.length} widths × ${SCHEMES.length} themes)`);
  done.forEach((d) => console.log('flow ' + d));
  const byCombo = new Set(problems.map((p) => p.split(':')[0]));
  console.log(`${problems.length} problems in ${byCombo.size} places, ${Math.round((Date.now() - t0) / 1000)} s`);
  problems.slice(0, 80).forEach((p) => console.log('  ' + p));
  process.exit(problems.length ? 1 : 0);
})();
