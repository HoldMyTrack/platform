import { test } from 'node:test';
import assert from 'node:assert/strict';
import { CAMERA_UNMOVED, DEMO_VIEWS, NOTHING_SEEN, cameraStep, cardFor, isPlainClick, nextStep, onScreen, placePopover, stepsFor, tourStart, withCard } from '../src/ui/tour/tourRules.ts';

const start = (over) => tourStart({ requested: false, isDemo: false, hasActivities: true, seen: NOTHING_SEEN, ...over });

test('the tour waits for the history, then starts for a demo and is offered to an account with activities', () => {
  assert.equal(start({ hasActivities: null }), 'wait');
  assert.equal(start({ hasActivities: null, requested: true }), 'wait');
  assert.equal(start({ isDemo: true }), 'start');
  assert.equal(start({}), 'offer');
  // An empty map has nothing to show.
  assert.equal(start({ hasActivities: false }), 'none');
});

test('once seen it never comes back by itself, but a request always starts it', () => {
  const seen = { tour: true, cards: [] };
  assert.equal(start({ seen }), 'none');
  assert.equal(start({ seen, isDemo: true }), 'none');
  assert.equal(start({ seen, requested: true }), 'start');
  assert.equal(start({ requested: true, hasActivities: false }), 'start');
});

test('a card shows once, for Fog, Heatmap or the Stories tab, and never during the tour', () => {
  assert.equal(cardFor({ kind: 'mode', mode: 'fog' }, NOTHING_SEEN, false), 'fog');
  assert.equal(cardFor({ kind: 'mode', mode: 'heatmap' }, NOTHING_SEEN, false), 'heatmap');
  assert.equal(cardFor({ kind: 'mode', mode: 'normal' }, NOTHING_SEEN, false), null);
  assert.equal(cardFor({ kind: 'tab', tab: 'stories' }, NOTHING_SEEN, false), 'stories');
  assert.equal(cardFor({ kind: 'tab', tab: 'activities' }, NOTHING_SEEN, false), null);
  assert.equal(cardFor({ kind: 'mode', mode: 'fog' }, withCard(NOTHING_SEEN, 'fog'), false), null);
  assert.equal(cardFor({ kind: 'mode', mode: 'fog' }, NOTHING_SEEN, true), null);
});

test('withCard adds a card once', () => {
  const once = withCard(NOTHING_SEEN, 'fog');
  assert.deepEqual(once.cards, ['fog']);
  assert.equal(withCard(once, 'fog'), once);
});

test('the steps keep Normal together before Fog and Heatmap, and the demo gets its own Add text', () => {
  const steps = stepsFor({ isDemo: false });
  const firstOther = steps.findIndex((s) => s.mode !== 'normal');
  const lastOther = steps.findLastIndex((s) => s.mode !== 'normal');
  assert.ok(steps.slice(firstOther, lastOther + 1).every((s) => s.mode !== 'normal'));
  assert.ok(steps.slice(0, firstOther).every((s) => s.mode === 'normal'));
  assert.equal(steps.find((s) => s.id === 'add').text, 'tour.add');
  assert.equal(stepsFor({ isDemo: true }).find((s) => s.id === 'add').text, 'tour.add_demo');
});

test("a demo's Fog is city, states and countries at Fog's own zoom tiers, and only the demo moves the camera", () => {
  const demo = stepsFor({ isDemo: true });
  const fog = demo.filter((s) => s.mode === 'fog');
  assert.deepEqual(fog.map((s) => s.id), ['fog', 'fog_regions', 'fog_countries']);
  // Exact coverage from zoom 7, regions 3–6, countries 0–2 (SPEC.md FR-4.2).
  assert.ok(fog[0].view.zoom >= 7);
  assert.ok(fog[1].view.zoom >= 3 && fog[1].view.zoom < 7);
  assert.ok(fog[2].view.zoom < 3);
  assert.equal(demo.find((s) => s.id === 'heatmap').view, DEMO_VIEWS.heatmapCity);
  // The fog card goes with the first Fog step only.
  assert.deepEqual(demo.filter((s) => s.card === 'fog').map((s) => s.id), ['fog']);
  assert.ok(stepsFor({ isDemo: false }).every((s) => s.view === null));
});

test("the demo's steps fly through its views and back; a real account's never move", () => {
  const current = { center: [-81.8, 41.4], zoom: 13 };
  const walk = (steps) => {
    let camera = CAMERA_UNMOVED;
    return steps.map((step) => {
      const { camera: next, move } = cameraStep(camera, step, current);
      camera = next;
      return move;
    });
  };
  const demo = stepsFor({ isDemo: true });
  const moves = walk(demo);
  const at = (id) => moves[demo.findIndex((s) => s.id === id)];
  assert.equal(at('welcome'), null);
  assert.equal(at('fog'), DEMO_VIEWS.city);
  assert.equal(at('heatmap'), DEMO_VIEWS.heatmapCity);
  // The step after Heatmap goes back to the view before the tour's first move, the Stories tab's.
  assert.deepEqual(at('add'), current);
  // A real account's Stories step lets the map frame its Story, and the next step brings it back.
  const real = stepsFor({ isDemo: false });
  const realMoves = walk(real);
  assert.equal(realMoves[real.findIndex((s) => s.id === 'stories')], null);
  assert.deepEqual(realMoves[real.findIndex((s) => s.id === 'layers')], current);
  for (const move of realMoves.filter((m) => m !== null)) assert.deepEqual(move, current);
});

test("countries are a flat world on a wide screen and a turning globe on a phone", () => {
  const countries = (narrow) => stepsFor({ isDemo: true, narrow }).find((s) => s.id === 'fog_countries').view;
  assert.equal(countries(false), DEMO_VIEWS.countries);
  assert.equal(countries(false).flat, true);
  assert.equal(countries(true), DEMO_VIEWS.countriesNarrow);
  assert.ok(countries(true).turn.length > 0);
});

test("the globe's turn goes east in legs under 180°, from the US to Vietnam", () => {
  const { center, turn } = DEMO_VIEWS.countriesNarrow;
  const points = [center, ...turn];
  for (let i = 1; i < points.length; i++) {
    const leg = points[i][0] - points[i - 1][0];
    assert.ok(leg > 0 && leg < 180, `leg ${i}: ${leg}°`);
  }
});

test('a step opens what it explains: the Stories tab, the sheet, Layers, and Upload for an account that can upload', () => {
  const steps = (isDemo) => Object.fromEntries(stepsFor({ isDemo }).map((s) => [s.id, s]));
  const real = steps(false);
  assert.equal(real.stories.tab, 'stories');
  assert.ok(real.stories.open.sheet && real.activities.open.sheet);
  assert.ok(real.layers.open.layers);
  assert.ok(real.add.open.upload);
  assert.equal(steps(true).add.open.upload, undefined);
  // Every other step is on the Activities tab, which the tour leaves for the Stories step alone.
  assert.ok(Object.values(real).filter((s) => s.id !== 'stories').every((s) => s.tab === 'activities'));
});

test('nextStep skips steps off screen and stops at either end', () => {
  const steps = stepsFor({ isDemo: false });
  const hidden = new Set(['range', 'stories']);
  const shown = (s) => !hidden.has(s.id);
  const at = (id) => steps.findIndex((s) => s.id === id);
  assert.equal(nextStep(steps, at('activities'), 1, shown), at('layers'));
  assert.equal(nextStep(steps, at('layers'), -1, shown), at('activities'));
  assert.equal(nextStep(steps, at('done'), 1, shown), null);
  assert.equal(nextStep(steps, 0, -1, shown), null);
  // The welcome has no anchor, so it shows whatever `shown` says.
  assert.equal(nextStep(steps, at('activities'), -1, () => false), 0);
});

test('the popover goes below its anchor, else above, else beside, clamped in the viewport', () => {
  const viewport = { width: 1280, height: 800 };
  const size = { width: 360, height: 200 };
  assert.deepEqual(placePopover({ left: 600, top: 20, width: 200, height: 40 }, size, viewport), { kind: 'float', left: 520, top: 74, side: 'below', arrow: 180 });
  const above = placePopover({ left: 600, top: 700, width: 200, height: 40 }, size, viewport);
  assert.equal(above.side, 'above');
  assert.equal(above.top, 700 - 14 - 200);
  // A tall panel down the left edge: the popover goes to its right.
  const right = placePopover({ left: 0, top: 50, width: 300, height: 740 }, size, viewport);
  assert.equal(right.side, 'right');
  assert.equal(right.left, 314);
  // Near the right edge it's clamped, and the arrow still points at the anchor.
  const clamped = placePopover({ left: 1220, top: 20, width: 40, height: 40 }, size, viewport);
  assert.equal(clamped.left, 1280 - 360 - 12);
  assert.equal(clamped.arrow, 1240 - clamped.left);
  assert.deepEqual(placePopover(null, size, viewport), { kind: 'center' });
  const phone = { width: 390, height: 844 };
  assert.deepEqual(placePopover({ left: 0, top: 0, width: 10, height: 10 }, size, phone), { kind: 'sheet', edge: 'bottom' });
  assert.deepEqual(placePopover(null, size, phone), { kind: 'sheet', edge: 'bottom' });
  // The panel's strip at the foot of a phone: the sheet goes to the top.
  assert.deepEqual(placePopover({ left: 0, top: 790, width: 390, height: 54 }, size, phone), { kind: 'sheet', edge: 'top' });
  // The panel's open sheet fills the screen below its tabs: no room above, so the bottom.
  assert.deepEqual(placePopover({ left: 0, top: 170, width: 390, height: 674 }, size, phone), { kind: 'sheet', edge: 'bottom' });
});

test('onScreen needs a laid-out rect overlapping the viewport', () => {
  const viewport = { width: 1280, height: 800 };
  assert.equal(onScreen({ left: 10, top: 10, width: 50, height: 20 }, viewport), true);
  assert.equal(onScreen({ left: 0, top: 0, width: 0, height: 0 }, viewport), false);
  assert.equal(onScreen({ left: 10, top: 900, width: 50, height: 20 }, viewport), false);
});

test('only a plain primary click is taken over from the header link', () => {
  const click = { button: 0, metaKey: false, ctrlKey: false, shiftKey: false, altKey: false };
  assert.equal(isPlainClick(click), true);
  assert.equal(isPlainClick({ ...click, metaKey: true }), false);
  assert.equal(isPlainClick({ ...click, button: 1 }), false);
});