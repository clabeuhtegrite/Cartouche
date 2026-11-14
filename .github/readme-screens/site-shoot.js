// Research only, removed before the merge: this branch's site with the games'
// covers, for the review of the Mac beside the iPad:
// node site-shoot.js BEFORE_DIR AFTER_DIR OUT_DIR (BEFORE_DIR unused this time)
// The iPad and Mac section and the Builder section on their own, twice the
// size, 1440 and 390 points wide, in English and French, and the whole page
// in French.
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
      if (lang === 'fr') {
        const context = await browser.newContext({ viewport: { width, height }, deviceScaleFactor: 1, locale: 'fr-FR', reducedMotion: 'reduce' });
        const page = await context.newPage();
        await page.addInitScript(() => { try { localStorage.setItem('cartouche.site.lang', 'fr'); } catch (e) {} });
        await page.goto(url, { waitUntil: 'load' });
        await settle(page);
        await page.screenshot({ path: `${out}/after-${device}-fr-full.png`, fullPage: true });
        await context.close();
      }
      // Each section alone, twice the size, the sticky bar out of it.
      const big = await browser.newContext({ viewport: { width, height }, deviceScaleFactor: 2,
        locale: lang === 'fr' ? 'fr-FR' : 'en-US', reducedMotion: 'reduce' });
      const p2 = await big.newPage();
      await p2.addInitScript(l => { try { localStorage.setItem('cartouche.site.lang', l); } catch (e) {} }, lang);
      await p2.goto(url, { waitUntil: 'load' });
      await settle(p2);
      await p2.addStyleTag({ content: 'header.top { visibility: hidden !important; }' });
      for (const [id, name] of [['#ipad-mac', 'ipad-mac'], ['#builder', 'builder']]) {
        const section = await p2.$(id);
        await section.scrollIntoViewIfNeeded();
        await p2.waitForTimeout(800);
        await section.screenshot({ path: `${out}/after-${device}-${lang}-${name}.png` });
      }
      await big.close();
    }
  }
  server.close();
  await browser.close();
})();
