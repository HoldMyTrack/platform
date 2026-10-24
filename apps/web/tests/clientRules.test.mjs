import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import { rules } from './clientRuleAdapters.mjs';

// The cases every client runs (testdata/client-rules/README.md). Mounted at /testdata in the
// web container, which this path also reaches.
const dir = new URL('../../../testdata/client-rules/', import.meta.url);

/** Equal as JSON, numbers within `tolerance`. */
function assertClose(actual, expected, tolerance, path = '') {
  if (typeof expected === 'number' && typeof actual === 'number') {
    assert.ok(Math.abs(actual - expected) <= tolerance, `${path || 'value'}: ${actual} is not within ${tolerance} of ${expected}`);
  } else if (Array.isArray(expected)) {
    assert.ok(Array.isArray(actual) && actual.length === expected.length, `${path || 'value'}: ${JSON.stringify(actual)} is not ${JSON.stringify(expected)}`);
    expected.forEach((item, i) => assertClose(actual[i], item, tolerance, `${path}[${i}]`));
  } else if (expected !== null && typeof expected === 'object') {
    assert.ok(actual !== null && typeof actual === 'object' && !Array.isArray(actual), `${path || 'value'}: ${JSON.stringify(actual)} is not an object`);
    // A missing field means the same as null.
    for (const key of new Set([...Object.keys(expected), ...Object.keys(actual)])) {
      assertClose(actual[key] ?? null, expected[key] ?? null, tolerance, `${path}.${key}`);
    }
  } else {
    assert.equal(actual, expected, path || 'value');
  }
}

// Every file whose `clients`, when it names any, include the web.
const files = readdirSync(dir)
  .filter((name) => name.endsWith('.json'))
  .filter((name) => JSON.parse(readFileSync(new URL(name, dir), 'utf8')).clients?.includes('web') ?? true);

test('every shared rule file has a web implementation', () => {
  for (const name of files) {
    const { rule } = JSON.parse(readFileSync(new URL(name, dir), 'utf8'));
    assert.ok(rules[rule], `${name}: no web implementation of ${rule}`);
  }
});

for (const name of files) {
  const { rule, cases, generated = [], tolerance: fileTolerance } = JSON.parse(readFileSync(new URL(name, dir), 'utf8'));
  for (const { name: caseName, input, expected, tolerance } of [...cases, ...generated]) {
    test(`${rule}: ${caseName}`, () => {
      if (expected?.throws === true) {
        assert.throws(() => rules[rule](input));
        return;
      }
      const actual = rules[rule](input);
      const within = tolerance ?? fileTolerance;
      if (within === undefined) assert.deepEqual(actual, expected);
      else assertClose(actual, expected, within);
    });
  }
}
