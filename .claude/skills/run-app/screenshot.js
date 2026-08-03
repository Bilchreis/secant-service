// Screenshot helper for the secant-service dashboard.
// Run from a directory where `playwright` is installed (agent scratchpad):
//   node screenshot.js <url> <out.png> [--wait-gone <text>] [--theme light|dark]
//
// Waits for LiveView to connect and (optionally) for a loading
// placeholder to disappear before shooting — a plain
// `google-chrome --screenshot` fires on the load event and misses
// anything the websocket pushes afterwards (e.g. ECharts plots).

// Resolve playwright from the invoking directory (the scratchpad),
// not from this script's location inside the repo.
const { createRequire } = require('module');
const { chromium } = createRequire(`${process.cwd()}/`)('playwright');

const args = process.argv.slice(2);
const url = args[0] || 'http://localhost:4000/dashboard';
const out = args[1] || 'screenshot.png';
const waitGone = args.includes('--wait-gone')
  ? args[args.indexOf('--wait-gone') + 1]
  : 'Waiting for valid Plot Data';
const theme = args.includes('--theme') ? args[args.indexOf('--theme') + 1] : 'dark';

(async () => {
  const browser = await chromium.launch({ channel: 'chrome', headless: true });
  const page = await (await browser.newContext({
    viewport: { width: 2560, height: 1440 },
    colorScheme: theme,
  })).newPage();

  const errors = [];
  page.on('console', (msg) => msg.type() === 'error' && errors.push(msg.text()));

  await page.goto(url);
  if (waitGone && waitGone !== 'none') {
    const placeholder = page.getByText(waitGone);
    try {
      await placeholder.first().waitFor({ state: 'visible', timeout: 10000 });
      await placeholder.first().waitFor({ state: 'hidden', timeout: 60000 });
    } catch {
      // placeholder never appeared (page has none) or never cleared — shoot anyway
    }
  }
  await page.waitForTimeout(500); // let ECharts finish painting
  await page.screenshot({ path: out });

  errors.forEach((e) => console.error('console error:', e));
  console.log(`saved ${out}`);
  await browser.close();
})();
