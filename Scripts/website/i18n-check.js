// Checks website/i18n/<lang>.json against the strings website/index.html asks for.
// Every string goes through t('简体中文原文', …args); this reads each literal key from the source and reports, per language,
// keys with no translation, translations nobody asks for any more, {0} placeholders that do not match, and translations that
// still contain Chinese (zh-Hant excepted). Calls whose first argument is not a plain literal are listed too.
// Usage: node Scripts/website/i18n-check.js            -> report, exit 1 on any problem
//        node Scripts/website/i18n-check.js --missing de -> the keys de.json lacks, as JSON to fill in
const fs = require('fs');
const path = require('path');

const site = path.resolve(__dirname, '../../website');
const src = fs.readFileSync(path.join(site, 'index.html'), 'utf8');
const LANGS = ['zh-Hant', 'en', 'ja', 'ko', 'de', 'fr', 'es', 'it'];

function readLiteral(i) {
  const q = src[i];
  if (q !== "'" && q !== '"') return null;
  let j = i + 1;
  while (src[j] !== q) { if (src[j] === '\\') j++; if (src[j] === '\n' || j >= src.length) return null; j++; }
  return { value: Function('return ' + src.slice(i, j + 1))(), end: j + 1 };
}
const keys = new Set();
const odd = [];
for (const m of src.matchAll(/(^|[^\w$.])t\(/g)) {
  const at = m.index + m[0].length;
  const lit = readLiteral(at);
  if (lit) keys.add(lit.value);
  else if (!/^s,\.\.\.args\)/.test(src.slice(at, at + 12))) odd.push(src.slice(at - 2, at + 60).replace(/\n/g, ' '));
}

const holes = (s) => (s.match(/\{\d+\}/g) || []).sort().join(',');
const tags = (s) => (s.match(/<\/?[a-z]+/g) || []).sort().join(',');
const han = /[㐀-鿿豈-﫿]/;

const want = process.argv.indexOf('--missing');
if (want > 0) {
  const lang = process.argv[want + 1];
  const file = path.join(site, 'i18n', lang + '.json');
  const dict = fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, 'utf8')) : {};
  const out = {};
  for (const k of keys) if (dict[k] == null) out[k] = '';
  console.log(JSON.stringify(out, null, 1));
  process.exit(0);
}

let problems = 0;
console.log(`${keys.size} strings in index.html`);
if (odd.length) { problems += odd.length; console.log('t() calls without a literal key:'); odd.forEach((x) => console.log('  ' + x)); }
for (const lang of LANGS) {
  const file = path.join(site, 'i18n', lang + '.json');
  if (!fs.existsSync(file)) { console.log(`${lang}: no file`); problems++; continue; }
  const dict = JSON.parse(fs.readFileSync(file, 'utf8'));
  const missing = [...keys].filter((k) => typeof dict[k] !== 'string' || !dict[k].trim());
  const extra = Object.keys(dict).filter((k) => !keys.has(k));
  const badHoles = [...keys].filter((k) => dict[k] && holes(k) !== holes(dict[k]));
  const badTags = [...keys].filter((k) => dict[k] && tags(k) !== tags(dict[k]));
  // Chinese left in a translation. The demo's typed Chinese words (预约…) and the native language names are meant to stay;
  // Japanese is written with kanji, so it is skipped here (missing keys still show up above).
  const allowed = /预约|会议|周末|发票|提醒|推迟|截止日期|报销|简体中文|繁體中文|日本語/g;
  const chinese = lang === 'zh-Hant' || lang === 'ja' ? [] : [...keys].filter((k) => dict[k] && han.test(dict[k].replace(allowed, '')));
  const n = missing.length + extra.length + badHoles.length + badTags.length + chinese.length;
  problems += n;
  console.log(`${lang}: ${Object.keys(dict).length} entries, ${missing.length} missing, ${extra.length} unused, ${badHoles.length} placeholder mismatches, ${badTags.length} tag mismatches, ${chinese.length} with Chinese left`);
  for (const [label, list] of [['missing', missing], ['unused', extra], ['placeholders', badHoles], ['tags', badTags], ['chinese', chinese]]) {
    list.slice(0, 8).forEach((k) => console.log(`   ${label}: ${k.slice(0, 70)}`));
    if (list.length > 8) console.log(`   … ${list.length - 8} more`);
  }
}
process.exit(problems ? 1 : 0);
