// Builds the website's generated files:
//   website/icon.svg    the app icon (light rounded tile with the cream quill), drawn like Assets/textwarden_logo.icon
//   website/icon.png    the same at 512 px, for apple-touch-icon
//   website/preview.png the 1200 × 630 share image (og:image), a screenshot of the running site
// Usage: NODE_PATH=$(npm root -g) node Scripts/website/make-assets.js http://127.0.0.1:8737/website/
// The site must be served at that address (python3 -m http.server from the repo root).
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');

const root = path.resolve(__dirname, '../..');
const site = process.argv[2];
if (!site) throw new Error('usage: make-assets.js <url of the served website/ folder>');

// Feather placement measured from the app icon the dev build ships (textwarden_logo.icns): the quill spans
// 31–69 % of the tile's width and 6.6–93.4 % of its height. In the 1024 source the quill's box is x 357–704, y 127–906.
const feather = fs.readFileSync(path.join(root, 'Assets/textwarden_feather_logo.svg'), 'utf8');
const paths = feather.slice(feather.indexOf('>', feather.indexOf('<svg')) + 1, feather.lastIndexOf('</svg>'));
const scale = (0.868 * 1024) / 779;
const tx = 0.311 * 1024 - 357 * scale;
const ty = 0.066 * 1024 - 127 * scale;
const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 1024 1024">`
  + `<defs><linearGradient id="tile" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#F2F2F2"/>`
  + `<stop offset=".35" stop-color="#ECECEC"/><stop offset="1" stop-color="#D6D6D6"/></linearGradient></defs>`
  + `<rect x="4" y="4" width="1016" height="1016" rx="228" fill="url(#tile)" stroke="#000" stroke-opacity=".1" stroke-width="8"/>`
  + `<rect x="14" y="14" width="996" height="996" rx="218" fill="none" stroke="#fff" stroke-opacity=".8" stroke-width="8"/>`
  + `<g transform="translate(${tx.toFixed(1)} ${ty.toFixed(1)}) scale(${scale.toFixed(4)})">${paths}</g></svg>\n`;
fs.writeFileSync(path.join(root, 'website/icon.svg'), svg);

(async () => {
  const browser = await chromium.launch({ executablePath: process.env.PW_CHROME || undefined });
  const page = await browser.newPage({ viewport: { width: 512, height: 512 } });
  await page.setContent(`<body style="margin:0;background:transparent">${svg.replace('width="64" height="64"', 'width="512" height="512"')}</body>`);
  await page.screenshot({ path: path.join(root, 'website/icon.png'), omitBackground: true });

  // laid out at 1440 wide (the desktop design) and scaled down to the 1200 × 630 share size
  const og = await browser.newPage({ viewport: { width: 1440, height: 756 }, deviceScaleFactor: 1200 / 1440, colorScheme: 'light' });
  await og.route(/^https:\/\/api\.github\.com\//, (r) => r.fulfill({ status: 200, contentType: 'application/json', body: '[]' }));
  await og.goto(site + 'index.html?lang=zh');
  await og.waitForTimeout(5200); // the hero demo has typed 预约 and shown the card by now
  await og.screenshot({ path: path.join(root, 'website/preview.png') });
  await browser.close();
  console.log('icon.svg, icon.png, preview.png written');
})();
