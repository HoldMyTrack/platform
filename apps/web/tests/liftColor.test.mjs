import { test } from 'node:test';
import assert from 'node:assert/strict';
import { liftColor } from '../src/map/liftColor.ts';

test('a colour is mixed toward white by the amount, its alpha kept', () => {
  assert.equal(liftColor('#1f1f1f', 0.08), '#313131');
  assert.equal(liftColor('#000000', 0.5), '#808080');
  assert.equal(liftColor('#FFFFFF', 0.3), '#ffffff');
  assert.equal(liftColor('rgba(30, 41, 31, 1)', 0.08), 'rgba(48, 58, 49, 1)');
  assert.equal(liftColor('rgba(30, 41, 31, 0.5)', 0), 'rgba(30, 41, 31, 0.5)');
  assert.equal(liftColor('rgb(0, 0, 0)', 0.1), 'rgba(26, 26, 26, 1)');
});

test('anything that is not a colour it knows passes through', () => {
  assert.equal(liftColor('hsl(0, 0%, 10%)', 0.5), 'hsl(0, 0%, 10%)');
  assert.equal(liftColor('Noto Sans', 0.5), 'Noto Sans');
});
