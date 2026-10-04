import assert from 'node:assert/strict';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

process.env.SUPABASE_URL ??= 'http://localhost';
process.env.SUPABASE_ANON_KEY ??= 'test';
const { runGeometry } = await import('../src/services/geometryBridge.js');

const options = {
  python: process.execPath,
  args: [fileURLToPath(new URL('./fixtures/fakeEngine.mjs', import.meta.url))],
  cwd: fileURLToPath(new URL('.', import.meta.url)),
  timeoutMs: 500,
};

test('ok resolves the drawing files', async () => {
  const result = await runGeometry('draw', { mode: 'ok' }, options);
  assert.deepEqual(result.files, ['elevation-A.dxf']);
});

test('invalid rejects with status 422 and validation details', async () => {
  await assert.rejects(runGeometry('draw', { mode: 'invalid' }, options), (err) => {
    assert.equal(err.status, 422);
    assert.deepEqual(err.details[0].loc, ['units']);
    return true;
  });
});

test('crash rejects with status 502 and stderr', async () => {
  await assert.rejects(runGeometry('draw', { mode: 'crash' }, options), (err) => {
    assert.equal(err.status, 502);
    assert.match(err.message, /boom/);
    return true;
  });
});

test('hang rejects with status 504', async () => {
  await assert.rejects(runGeometry('draw', { mode: 'hang' }, options), (err) => {
    assert.equal(err.status, 504);
    return true;
  });
});
