import { test } from 'node:test';
import assert from 'node:assert/strict';
import { fogRadio, onScreen, panelExpanded, toPanel, zoomPlan } from '../../../brand/play/source/rules.mjs';

test('toPanel maps a full-panel screen corner to corner', () => {
  const g = { pw: 1080, ph: 2400, w: 1080, h: 2400 };
  assert.deepEqual(toPanel(g, 0, 0), [0, 0]);
  assert.deepEqual(toPanel(g, 1080, 2400), [32767, 32767]);
});

test('toPanel letterboxes a shorter override inside the panel', () => {
  // 1080×1920 on a 1080×2400 panel: full width, 240 px of letterbox above and below.
  const g = { pw: 1080, ph: 2400, w: 1080, h: 1920 };
  assert.deepEqual(toPanel(g, 0, 0), [0, Math.round((240 / 2400) * 32767)]);
  assert.deepEqual(toPanel(g, 540, 960), [Math.round(32767 / 2), Math.round(32767 / 2)]);
});

test('toPanel scales an override larger than the panel down to fit', () => {
  // 1440×2560 on 1080×2400: scaled by 0.75 to 1080×1920, centred vertically.
  const g = { pw: 1080, ph: 2400, w: 1440, h: 2560 };
  assert.deepEqual(toPanel(g, 1440, 0), [32767, Math.round((240 / 2400) * 32767)]);
});

const total = (p) => p.pinch - p.outTaps + p.inTaps;
const pinchable = (p) => Math.abs(p.pinch) >= 2 && Math.abs(p.pinch) <= 3;

test('zoomPlan pinches a zoom of 2 to 3 levels either way as is', () => {
  for (const levels of [2, 2.5, 3, -2, -2.2, -3]) assert.deepEqual(zoomPlan(levels), { pinch: levels, outTaps: 0, inTaps: 0 });
});

test('zoomPlan makes a smaller zoom a bigger pinch taken back by taps out', () => {
  for (const levels of [-1.33, -1, -0.48, 0, 0.5, 1.9, -3.5, -5]) {
    const p = zoomPlan(levels);
    assert.ok(pinchable(p), `${levels}: pinch ${p.pinch}`);
    assert.equal(p.inTaps, 0);
    assert.ok(Math.abs(total(p) - levels) < 1e-9, `${levels}: totals ${total(p)}`);
  }
});

test('zoomPlan zooms past 3 levels in with double taps', () => {
  for (const levels of [3.5, 4, 7.2]) {
    const p = zoomPlan(levels);
    assert.ok(pinchable(p), `${levels}: pinch ${p.pinch}`);
    assert.equal(p.outTaps, 0);
    assert.ok(Math.abs(total(p) - levels) < 1e-9);
  }
});

test('zoomPlan refuses a zoom that is not a number', () => {
  assert.throws(() => zoomPlan(NaN));
  assert.throws(() => zoomPlan(Infinity));
});

test('fogRadio finds a level by its label, Auto with its hint', () => {
  const radios = [
    { id: 'fog_level_radio', text: 'Авто  по масштабу' },
    { id: 'fog_level_radio', text: 'Город' },
    { id: 'fog_level_radio', text: 'Точно' },
    { id: 'other', text: 'Город' },
  ];
  assert.equal(fogRadio(radios, 'Город'), radios[1]);
  assert.equal(fogRadio(radios, 'Авто'), radios[0]);
  assert.equal(fogRadio(radios, 'Гор'), undefined);
  assert.equal(fogRadio(radios, 'City'), undefined);
});

test('panelExpanded reads whether the panel list is on screen', () => {
  assert.equal(panelExpanded([{ id: 'panel_handle' }, { id: 'panel_summary' }]), false);
  assert.equal(panelExpanded([{ id: 'panel_handle' }, { id: 'panel_list' }]), true);
  assert.equal(panelExpanded([{ id: 'trips_list' }]), true);
});

test('onScreen takes the screen\'s pixels, 0 to one less than its size', () => {
  const g = { w: 1080, h: 1920 };
  assert.ok(onScreen(g, 0, 0));
  assert.ok(onScreen(g, 1079, 1919));
  assert.ok(!onScreen(g, 1080, 960));
  assert.ok(!onScreen(g, 540, 1920));
  assert.ok(!onScreen(g, -1, 960));
});
