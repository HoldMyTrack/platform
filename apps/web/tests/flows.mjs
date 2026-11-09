/**
 * End-to-end flows over the map's state rules: an upload reaching an empty account, Dates
 * narrowing the list and keeping the selection, a Story opened and closed by Back, a track edit's
 * reprocess, a delete, the area's button below zoom 10, the Dates menu, the header's menus
 * closing, and the tour's offer and header link. Each run signs up a fresh account, uploads the
 * sample files, and deletes the account at the end.
 *
 *   npm run verify:map
 *
 * Needs the API and the worker running: uploads are parsed by a job.
 */
import { spawn } from 'node:child_process';
import { after, before, describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { chromium } from 'playwright';

const PORT = 5181;
const BASE = `http://localhost:${PORT}`;
const API_BASE = process.env.VITE_API_BASE_URL ?? 'http://localhost:8080';
const EMAIL = `flows-${Date.now()}-${process.pid}@holdmytrack.local`;
const PASSWORD = 'flows-test-password';
// Served from services/server/internal/web/static/testing, dated 1, 5 and 6 Oct 2026.
const SAMPLES = ['west-side.gpx', 'evening-loop.tcx', 'mill-creek-falls.fit'];

let server;
let browser;
let context;
let page;

const rows = () => page.locator('li[data-activity-id]');
const checkedBoxes = () => page.locator('li[data-activity-id] input.activities-panel__checkbox:checked');
const hiddenRows = () => page.locator('li.activities-panel__row--hidden');
const row = (id) => page.locator(`li[data-activity-id="${id}"]`);

async function waitForServer(url, timeoutMs = 60_000) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    try {
      if ((await fetch(url)).ok) return;
    } catch {
      // not up yet
    }
    if (Date.now() > deadline) throw new Error(`dev server never became ready at ${url}`);
    await new Promise((r) => setTimeout(r, 250));
  }
}

async function call(method, path, data) {
  const res = await context.request.fetch(`${API_BASE}/v1${path}`, { method, data });
  if (!res.ok()) throw new Error(`${method} ${path}: ${res.status()} ${await res.text()}`);
  return res.status() === 204 ? null : res.json();
}

/** The account's activities, newest first, once none is pending. */
async function settledActivities(expected, timeoutMs = 90_000) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const { activities } = await call('GET', '/activities');
    if (activities.length === expected && activities.every((a) => !a.pending)) return activities;
    if (Date.now() > deadline) throw new Error(`expected ${expected} settled activities, have ${JSON.stringify(activities.map((a) => [a.id, a.pending]))}`);
    await new Promise((r) => setTimeout(r, 500));
  }
}

/** The map framed on every activity, and the list following it: on its own from zoom 10, through
 *  the area's button below (docs/SPEC.md FR-5.19). A camera move from here counts as the user's. */
async function viewAll() {
  const { activities } = await call('GET', '/activities');
  const boxes = activities.map((a) => a.bbox).filter(Boolean);
  const box = [Math.min(...boxes.map((b) => b[0])), Math.min(...boxes.map((b) => b[1])), Math.max(...boxes.map((b) => b[2])), Math.max(...boxes.map((b) => b[3]))];
  const zoom = await page.evaluate((b) => {
    const map = window.__holdmytrack;
    map.fitBounds([[b[0], b[1]], [b[2], b[3]]], { padding: 80, animate: false });
    return map.getZoom();
  }, box);
  if (zoom < 10) await page.getByTestId('activities-in-area').click();
  await page.waitForFunction((n) => document.querySelectorAll('li[data-activity-id]').length === n, activities.length, { timeout: 30_000 });
}

before(async () => {
  server = spawn('npx', ['vite', '--port', String(PORT), '--strictPort'], {
    cwd: new URL('..', import.meta.url).pathname,
    stdio: 'ignore',
  });
  await waitForServer(BASE);
  browser = await chromium.launch({ args: process.env.PW_CHROMIUM_ARGS?.split(/\s+/) ?? [] });
  context = await browser.newContext({ viewport: { width: 1280, height: 800 }, deviceScaleFactor: 1 });
  await call('POST', '/auth/signup', { email: EMAIL, password: PASSWORD });
  // A fresh account opens on the first-run setup until it has a Country (FR-1.7).
  await call('PATCH', '/account/settings', { display_name: '', country: 'US', timezone: 'America/New_York' });
  page = await context.newPage();
  await page.goto(`${BASE}/#map=3.00/40.00/-82.00&theme=light`);
  await page.waitForFunction(() => Boolean(window.__holdmytrack), undefined, { timeout: 60_000 }).catch(async (err) => {
    await page.screenshot({ path: new URL('./screenshots/flows-before.png', import.meta.url).pathname });
    console.error('URL', page.url());
    throw err;
  });
});

after(async () => {
  try {
    await call('DELETE', '/account', { email: EMAIL });
  } catch (err) {
    console.error('could not delete the flows account', err);
  }
  await browser?.close();
  server?.kill('SIGTERM');
});

describe('map flows', () => {
  let ids;

  it('1. an empty account picks up its first upload in the area in view', async () => {
    assert.equal(await rows().count(), 0);
    for (const name of SAMPLES) {
      const sample = await context.request.get(`${API_BASE}/static/testing/${name}`);
      assert.ok(sample.ok(), `sample ${name}: ${sample.status()}`);
      const upload = await context.request.post(`${API_BASE}/v1/activities/upload`, {
        multipart: { file: { name, mimeType: 'application/octet-stream', buffer: await sample.body() } },
      });
      assert.ok(upload.ok(), `upload ${name}: ${upload.status()} ${await upload.text()}`);
    }
    const activities = await settledActivities(SAMPLES.length);
    ids = Object.fromEntries(activities.map((a) => [a.started_at.slice(0, 10), a.id]));
    // What the header's Upload menu sends once its imports are done.
    await page.evaluate(() => window.dispatchEvent(new Event('hmt:imports-changed')));
    await rows().nth(SAMPLES.length - 1).waitFor({ timeout: 30_000 });
    assert.equal(await rows().count(), SAMPLES.length);
  });

  it('2. Dates narrow the list, keeping the checked group and the hidden tracks on what stays', async () => {
    const boxes = page.locator('li[data-activity-id] input.activities-panel__checkbox');
    // Newest first: 6 and 5 Oct.
    await boxes.nth(0).check();
    await boxes.nth(1).check();
    await page.locator('.activities-panel__visibility').click();
    assert.equal(await checkedBoxes().count(), 2);
    assert.equal(await hiddenRows().count(), 2);
    await page.getByTestId('dates-filter').click();
    await page.getByTestId('dates-after').fill('2026-10-05');
    await page.getByTestId('dates-after').press('Enter');
    await page.waitForFunction(() => document.querySelectorAll('li[data-activity-id]').length === 2, undefined, { timeout: 30_000 });
    assert.equal(await row(ids['2026-10-01']).count(), 0);
    assert.equal(await checkedBoxes().count(), 2);
    assert.equal(await hiddenRows().count(), 2);
    await page.keyboard.press('Escape');
    await page.getByTestId('dates-clear').click();
    assert.match(await page.getByTestId('dates-filter').textContent(), /All time/);
  });

  it('3. the Stories tab opens the newest Story in the URL, and Back returns to the area', async () => {
    await call('POST', '/stories', { name: 'Flows trip', activity_ids: [ids['2026-10-01'], ids['2026-10-06']] });
    await page.getByRole('tab', { name: 'Stories' }).click();
    await page.waitForURL(/[?&]story=/, { timeout: 30_000 });
    // The area's list shows until the Story's replaces it.
    await page.waitForFunction(() => document.querySelectorAll('li[data-activity-id]').length === 2, undefined, { timeout: 30_000 });
    await row(ids['2026-10-01']).waitFor({ timeout: 30_000 });
    assert.equal(await row(ids['2026-10-05']).count(), 0);
    await page.goBack();
    await page.waitForURL((url) => !url.searchParams.has('story'), { timeout: 30_000 });
    assert.equal(await page.getByRole('tab', { name: 'Activities' }).getAttribute('aria-selected'), 'true');
    // The area is wherever the Story left the camera, which frames both of its tracks.
    await row(ids['2026-10-01']).waitFor({ timeout: 30_000 });
    await row(ids['2026-10-06']).waitFor({ timeout: 30_000 });
  });

  it('4. an applied track edit goes Pending, and the poll picks up the shorter track', async () => {
    const id = ids['2026-10-05'];
    await viewAll();
    const before = (await call('GET', '/activities')).activities.find((a) => a.id === id).distance_meters;
    const metaBefore = await row(id).locator('.activities-panel__meta').textContent();
    await row(id).locator('.activities-panel__text').click();
    await page.locator('.activities-panel__edit').click();
    await page.getByTestId('edit-tab-track').click();
    const startKnob = page.getByLabel('Start of range');
    await startKnob.waitFor({ timeout: 30_000 });
    const max = Number(await startKnob.getAttribute('max'));
    await startKnob.fill(String(Math.round(max / 2)));
    await page.getByRole('button', { name: 'Chop', exact: true }).click();
    await page.getByTestId('edit-save').click();
    await page.getByTestId('edit-activity-window').waitFor({ state: 'detached', timeout: 30_000 });
    // The row comes back from Pending on its own, with the shorter distance.
    await page.waitForFunction(
      (rowId) => {
        const el = document.querySelector(`li[data-activity-id="${rowId}"]`);
        return el !== null && !el.classList.contains('activities-panel__row--pending');
      },
      id,
      { timeout: 60_000 },
    );
    const [after] = (await settledActivities(SAMPLES.length)).filter((a) => a.id === id);
    assert.ok(after.distance_meters < before, `distance ${after.distance_meters} not below ${before}`);
    await page.waitForFunction(
      ({ rowId, text }) => document.querySelector(`li[data-activity-id="${rowId}"] .activities-panel__meta`)?.textContent !== text,
      { rowId: id, text: metaBefore },
      { timeout: 30_000 },
    );
  });

  it('5. a deleted activity leaves the list, the map and the selection', async () => {
    const id = ids['2026-10-06'];
    await row(id).locator('input.activities-panel__checkbox').check();
    await page.locator('.activities-panel__delete').click();
    await page.locator('.confirm-dialog__confirm').click();
    await row(id).waitFor({ state: 'detached', timeout: 30_000 });
    assert.equal(await checkedBoxes().count(), 0);
    const { activities } = await call('GET', '/activities');
    assert.equal(activities.some((a) => a.id === id), false);
  });

  it('6. below zoom 10 a move waits for "Show activities in this area"', async () => {
    await viewAll();
    const listed = await rows().count();
    await page.evaluate(() => window.__holdmytrack.jumpTo({ center: [0, 0], zoom: 6 }));
    const button = page.getByTestId('activities-in-area');
    await button.waitFor({ timeout: 10_000 });
    // The list stays as it was until asked.
    assert.equal(await rows().count(), listed);
    await button.click();
    await button.waitFor({ state: 'detached', timeout: 10_000 });
    await page.waitForFunction(() => document.querySelectorAll('li[data-activity-id]').length === 0, undefined, { timeout: 30_000 });
  });

  it('7. the Dates menu offers the first activity as a hint, and ✕ clears it without moving the camera', async () => {
    await viewAll();
    await page.getByTestId('dates-filter').click();
    assert.match(await page.locator('.activities-panel__date-hint').first().textContent(), /Oct 1, 2026/);
    await page.getByTestId('dates-before').fill('2026-10-01');
    await page.getByTestId('dates-before').press('Enter');
    await page.waitForFunction(() => document.querySelectorAll('li[data-activity-id]').length === 1, undefined, { timeout: 30_000 });
    assert.match(await page.getByTestId('dates-filter').textContent(), /before Oct 1, 2026/);
    await page.keyboard.press('Escape');
    // Setting Dates flew the camera onto the match; clearing them must leave it where it landed.
    await page.waitForFunction(() => !window.__holdmytrack.isMoving(), undefined, { timeout: 10_000 });
    const center = await page.evaluate(() => window.__holdmytrack.getCenter().toArray());
    await page.getByTestId('dates-clear').click();
    assert.match(await page.getByTestId('dates-filter').textContent(), /All time/);
    assert.deepEqual(await page.evaluate(() => window.__holdmytrack.getCenter().toArray()), center);
  });

  it("8. the header's menus close on another menu, a click on the map and Escape", async () => {
    await page.goto(`${BASE}/#map=3.00/40.00/-82.00&theme=light`);
    await page.waitForFunction(() => Boolean(window.__holdmytrack));
    const open = () => page.evaluate(() => [...document.querySelectorAll('.page-header details[open]')].map((d) => d.className));
    await page.locator('.user-menu > summary').click();
    assert.deepEqual(await open(), ['header-menu user-menu']);
    await page.locator('.info-menu > summary').click();
    assert.deepEqual(await open(), ['header-menu info-menu']);
    await page.locator('.maplibregl-canvas').click({ position: { x: 400, y: 400 } });
    assert.deepEqual(await open(), []);
    await page.locator('.user-menu > summary').click();
    await page.keyboard.press('Escape');
    assert.deepEqual(await open(), []);
  });

  it("9. an account with activities is offered the tour once; the header's link starts it in place, and it puts the mode back", async () => {
    // Loaded with activities from the start, the map offers the tour.
    await page.reload();
    await page.getByTestId('tour-offer').waitFor({ timeout: 60_000 });
    await page.getByTestId('tour-offer-later').click();
    await page.getByTestId('tour-tip').waitFor();
    const activeMode = () => page.getByTestId('map-mode-toggle').locator('[aria-pressed="true"]').textContent();
    // No reload: the marker set on this page survives the click.
    await page.evaluate(() => (window.__tourMarker = true));
    await page.locator('[data-tour-start]').click();
    await page.getByTestId('tour').waitFor();
    assert.equal(await page.evaluate(() => window.__tourMarker), true);
    while ((await page.getByTestId('tour').getAttribute('data-step')) !== 'fog') await page.getByTestId('tour-next').click();
    assert.equal(await activeMode(), 'Fog');
    await page.keyboard.press('Escape');
    await page.getByTestId('tour').waitFor({ state: 'detached' });
    assert.equal(await activeMode(), 'Normal');
    // Declined once, never offered again; from another page the link opens the map on the tour.
    await page.goto(`${BASE}/profile`);
    await page.locator('[data-tour-start]').click();
    await page.getByTestId('tour').waitFor({ timeout: 60_000 });
    assert.equal(new URL(page.url()).searchParams.has('tour'), false);
    await page.reload();
    await page.waitForFunction(() => Boolean(window.__holdmytrack));
    await page.waitForTimeout(2000);
    assert.equal(await page.getByTestId('tour').count(), 0);
    assert.equal(await page.getByTestId('tour-offer').count(), 0);
  });
});
