// Every relative import names its file's extension: the unit tests run sources through Node's
// type stripping, which resolves nothing else, so a module imported without one can't be tested
// until its imports are rewritten.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';

function sources(dir) {
  return readdirSync(dir).flatMap((name) => {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) return sources(path);
    return /\.tsx?$/.test(name) && name !== 'apiSchema.ts' ? [path] : [];
  });
}

test('every relative import names its extension', () => {
  const src = new URL('../src', import.meta.url).pathname;
  const bare = sources(src).flatMap((file) =>
    [...readFileSync(file, 'utf8').matchAll(/(?:from|import)\s*\(?\s*['"](\.{1,2}\/[^'"]+)['"]/g)]
      .map((m) => m[1])
      .filter((spec) => !/\.(tsx?|css|png|svg|json)$/.test(spec))
      .map((spec) => `${file.slice(src.length + 1)}: ${spec}`),
  );
  assert.deepEqual(bare, []);
});
