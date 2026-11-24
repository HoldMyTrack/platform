import { test } from 'node:test';
import assert from 'node:assert/strict';
import { appBridge } from '../src/library/appBridge.ts';

test('the app bridge is found only when it can download', () => {
  const bridge = { downloadGpx() {} };
  assert.equal(appBridge({ HoldMyTrackApp: bridge }), bridge);
  assert.equal(appBridge({}), null);
  assert.equal(appBridge({ HoldMyTrackApp: {} }), null);
});
