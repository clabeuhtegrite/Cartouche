// Research only, removed before the merge: this branch's site with the games'
// covers, for the review of the iPhone put back beside the iPad and the Mac:
// node site-shoot.js BEFORE_DIR AFTER_DIR OUT_DIR (BEFORE_DIR unused this time)
// The iPad and Mac section on its own, twice the size, 1440 and 390 points
// wide, in English and French. The window grows to the section before each
// shot: Chromium draws a nested size container wrong when it captures beyond
// the window, which a reader's browser never does.
const http = require('http');
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');
const [, afterDir, out] = process.argv.slice(2);
const TYPES = { '.html': 'text/html; charset=utf-8', '.svg': 'image/svg+xml', '.css': 'text/css', '.js': 'text/javascript' };

function serve(dir) {
  return new Promise(resolve => {
    const server = http.createServer((req, res) => {
      let p = decodeURIComponent(req.url.split('?')[0]);
      if (p.endsWith('/')) p += 'index.html';
      const f = path.join(dir, p);
      if (!f.startsWith(dir) || !fs.existsSync(f)) { res.writeHead(404); res.end(); return; }
      res.writeHead(200, { 'Content-Type': TYPES[path.extname(f)] || 'application/octet-stream' });
      fs.createReadStream(f).pipe(res);
    });
    server.listen(0, '127.0.0.1', () => resolve(server));
  });
}

async function settle(page) {
  // The covers load lazily: down the page and back, then until they are in.
  const height = await page.evaluate(() => document.documentElement.scrollHeight);
  for (let y = 0; y < height; y += 500) {
    await page.evaluate(v => window.scrollTo(0, v), y);
    await page.waitForTimeout(120);
  }
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.waitForLoadState('networkidle').catch(() => {});
  await page.waitForTimeout(1200);
}

(async () => {
  fs.mkdirSync(out, { recursive: true });
  const browser = await chromium.launch();
  const server = await serve(path.resolve(afterDir));
  const url = `http://127.0.0.1:${server.address().port}/`;
  for (const lang of ['en', 'fr']) {
    for (const [device, width, height] of [['desktop', 1440, 900], ['phone', 390, 844]]) {
      const context = await browser.newContext({ viewport: { width, height }, deviceScaleFactor: 2,
        locale: lang === 'fr' ? 'fr-FR' : 'en-US', reducedMotion: 'reduce' });
      const page = await context.newPage();
      await page.addInitScript(l => { try { localStorage.setItem('cartouche.site.lang', l); } catch (e) {} }, lang);
      await page.goto(url, { waitUntil: 'load' });
      await settle(page);
      await page.addStyleTag({ content: 'header.top { visibility: hidden !important; }' });
      const section = await page.$('#ipad-mac');
      const box = await section.boundingBox();
      await page.setViewportSize({ width, height: Math.max(height, Math.ceil(box.height) + 40) });
      await section.scrollIntoViewIfNeeded();
      await page.waitForLoadState('networkidle').catch(() => {});
      await page.waitForTimeout(1200);
      await section.screenshot({ path: `${out}/after-${device}-${lang}-ipad-mac.png` });
      await context.close();
    }
  }
  server.close();
  await browser.close();
})();
