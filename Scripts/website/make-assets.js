// Builds the website's generated files:
//   website/icon.svg     the app icon, bold version for 22 to 28 pt (navigation, footer, download card)
//   website/favicon.svg  the 32 px redraw for the browser tab
//   website/icon.png     512 px, for apple-touch-icon
//   website/preview.png  the 1200 × 630 share image (og:image), a screenshot of the running site
// The icons are copied from the picked design (design/icon/redesign/b, «羽毛成勾»), the same drawing as
// the app's own icon; only the share image is drawn here.
// Usage: NODE_PATH=$(npm root -g) node Scripts/website/make-assets.js http://127.0.0.1:8737/website/
// The site must be served at that address (python3 -m http.server from the repo root).
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');

const root = path.resolve(__dirname, '../..');
const site = process.argv[2];
if (!site) throw new Error('usage: make-assets.js <url of the served website/ folder>');

const icon = path.join(root, 'design/icon/redesign/b');
for (const [from, to] of [['icon.svg', 'icon.svg'], ['favicon.svg', 'favicon.svg'], ['export/web-icon-512.png', 'icon.png']]) {
  fs.copyFileSync(path.join(icon, from), path.join(root, 'website', to));
}

(async () => {
  const browser = await chromium.launch({ executablePath: process.env.PW_CHROME || undefined });
  // laid out at 1440 wide (the desktop design) and scaled down to the 1200 × 630 share size
  const og = await browser.newPage({ viewport: { width: 1440, height: 756 }, deviceScaleFactor: 1200 / 1440, colorScheme: 'light' });
  await og.route(/^https:\/\/api\.github\.com\//, (r) => r.fulfill({ status: 200, contentType: 'application/json', body: '[]' }));
  await og.goto(site + 'index.html?lang=zh');
  await og.waitForTimeout(5200); // the hero demo has typed 预约 and shown the card by now
  await og.screenshot({ path: path.join(root, 'website/preview.png') });
  await browser.close();
  console.log('icon.svg, favicon.svg, icon.png, preview.png written');
})();
