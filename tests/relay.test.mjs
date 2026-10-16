import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { once } from 'node:events';
import { createHash } from 'node:crypto';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createRelayServer } from '../server.mjs';

async function relay(t, options = {}) {
  const app = createRelayServer({ fallbackToken: '', ...options });
  app.server.listen(0, '127.0.0.1');
  await once(app.server, 'listening');
  t.after(() => { app.server.closeAllConnections(); app.server.close(); });
  const base = `http://127.0.0.1:${app.server.address().port}`;
  const request = (path, init) => fetch(base + path, init);
  const session = async () => (await (await request('/api/session', { method: 'POST' })).json()).code;
  const upload = (code, bytes, headers = {}) => request(`/api/room/${code}/image`, { method: 'POST', headers: { 'content-type': 'image/jpeg', ...headers }, body: bytes });
  return { ...app, base, request, session, upload };
}

test('image bytes round-trip exactly; unchanged metadata is bodyless 304', async t => {
  const app = await relay(t);
  const code = await app.session();
  const bytes = Buffer.alloc(450_000, 0x7d);
  assert.equal((await app.upload(code, bytes)).status, 201);
  const meta = await app.request(`/api/room/${code}/latest?meta=1`);
  const tag = meta.headers.get('etag');
  const text = await meta.text();
  assert.ok(text.length < 512);
  assert.equal(JSON.parse(text).image.data, undefined);
  for (let i = 0; i < 20; i++) {
    const response = await app.request(`/api/room/${code}/latest?meta=1`, { headers: { 'if-none-match': tag } });
    assert.equal(response.status, 304);
    assert.equal((await response.text()).length, 0);
  }
  const full = await app.request(`/api/room/${code}/latest`);
  const body = await full.text();
  assert.equal(Number(full.headers.get('content-length')), Buffer.byteLength(body));
  const actual = Buffer.from(JSON.parse(body).image.data, 'base64');
  assert.equal(createHash('sha256').update(actual).digest('hex'), createHash('sha256').update(bytes).digest('hex'));
  assert.equal(app.stats().retainedBytes, 600_000);
});

test('polling preserves pairing but expires old image memory', async t => {
  let clock = 10_000;
  const app = await relay(t, { now: () => clock, ttlMs: 100 });
  const code = await app.session();
  await app.upload(code, Buffer.alloc(600));
  const first = await app.request(`/api/room/${code}/latest?meta=1`);
  const tag = first.headers.get('etag');
  await first.arrayBuffer();
  clock += 60;
  await (await app.request(`/api/room/${code}/latest?meta=1`)).arrayBuffer();
  clock += 41;
  const expired = await app.request(`/api/room/${code}/latest?meta=1`, { headers: { 'if-none-match': tag } });
  assert.equal(expired.status, 200);
  assert.deepEqual(await expired.json(), { image: null });
  assert.equal(app.stats().retainedBytes, 0);
  assert.equal(app.stats().rooms, 1);
  clock += 101;
  app.sweep();
  assert.equal(app.stats().rooms, 0);
});

test('room and aggregate image limits reject work without losing last image', async t => {
  const app = await relay(t, { maxRetainedBytes: 800, maxRooms: 2, maxBytes: 1024 });
  const a = await app.session();
  const b = await app.session();
  assert.equal((await app.request('/api/session', { method: 'POST' })).status, 503);
  assert.equal((await app.upload(a, Buffer.alloc(600))).status, 201);
  assert.equal((await app.upload(b, Buffer.alloc(3))).status, 503);
  assert.equal((await app.upload(a, Buffer.alloc(1025))).status, 413);
  assert.equal((await app.upload(a, Buffer.alloc(300))).status, 201);
  assert.equal(app.stats().retainedBytes, 400);
  const latest = await (await app.request(`/api/room/${a}/latest`)).json();
  assert.equal(latest.image.size, 300);
});

test('pending uploads are bounded and aborted uploads release their slot', async t => {
  const app = await relay(t, { maxUploads: 1 });
  const code = await app.session();
  const held = http.request(`${app.base}/api/room/${code}/image`, { method: 'POST', headers: { 'content-type': 'image/jpeg', 'content-length': 100 } });
  held.on('error', () => {});
  held.write('x');
  for (let i = 0; i < 100 && app.stats().activeUploads !== 1; i++) await new Promise(resolve => setImmediate(resolve));
  assert.equal(app.stats().activeUploads, 1);
  assert.equal((await app.upload(code, Buffer.alloc(3))).status, 503);
  held.destroy();
  for (let i = 0; i < 100 && app.stats().activeUploads; i++) await new Promise(resolve => setImmediate(resolve));
  assert.equal(app.stats().activeUploads, 0);
});

test('SSE connection limits and disconnect cleanup', async t => {
  const app = await relay(t, { maxRoomClients: 1 });
  const code = await app.session();
  const controller = new AbortController();
  const stream = await app.request(`/api/room/${code}/events`, { signal: controller.signal });
  const reader = stream.body.getReader();
  assert.match(new TextDecoder().decode((await reader.read()).value), /connected/);
  assert.equal(app.stats().clients, 1);
  assert.equal((await app.request(`/api/room/${code}/events`)).status, 503);
  await app.upload(code, Buffer.alloc(12));
  assert.match(new TextDecoder().decode((await reader.read()).value), /event: image/);
  controller.abort();
  for (let i = 0; i < 100 && app.stats().clients; i++) await new Promise(resolve => setImmediate(resolve));
  assert.equal(app.stats().clients, 0);
});

test('archive concurrency is bounded; older failure cannot corrupt newer status', async t => {
  const jobs = [];
  const app = await relay(t, { maxArchives: 2, archive: () => new Promise((resolve, reject) => jobs.push({ resolve, reject })) });
  const code = await app.session();
  const headers = { 'x-sevenbu-token': 'synthetic-test-token' };
  await app.upload(code, Buffer.alloc(12), headers);
  await app.upload(code, Buffer.alloc(15), headers);
  assert.equal(app.stats().activeArchives, 2);
  const b = await app.session();
  const overloaded = await app.upload(b, Buffer.alloc(9), headers);
  assert.equal(overloaded.status, 201);
  assert.equal((await overloaded.json()).hostedStatus, 'failed');
  jobs[0].reject(new Error('older request failed'));
  await new Promise(resolve => setImmediate(resolve));
  const before = await app.request(`/api/room/${code}/latest?meta=1`);
  const tag = before.headers.get('etag');
  assert.equal((await before.json()).image.hostedStatus, 'pending');
  jobs[1].resolve({ status: 'completed', url: 'https://example.invalid/test.jpg' });
  await new Promise(resolve => setImmediate(resolve));
  const after = await app.request(`/api/room/${code}/latest?meta=1`, { headers: { 'if-none-match': tag } });
  assert.equal(after.status, 200);
  assert.equal((await after.json()).image.hostedStatus, 'completed');
  assert.equal(app.stats().activeArchives, 0);
});

test('static download supports HEAD and byte-identical streaming', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'pocket-static-test-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  await writeFile(join(directory, 'styles.css'), 'body { color: green; }\n');
  const app = await relay(t, { publicDir: directory });
  const head = await app.request('/styles.css', { method: 'HEAD' });
  assert.equal(head.status, 200);
  assert.equal((await head.arrayBuffer()).byteLength, 0);
  const get = await app.request('/styles.css');
  assert.equal((await get.arrayBuffer()).byteLength, Number(head.headers.get('content-length')));
});

test('slow image readers cannot pin unlimited old image buffers', async t => {
  const app = await relay(t, { maxImageDownloads: 1 });
  const code = await app.session();
  await app.upload(code, Buffer.alloc(8 * 1024 * 1024, 0x33));
  const held = http.get(`${app.base}/api/room/${code}/latest`);
  const [response] = await once(held, 'response');
  response.pause();
  assert.equal(app.stats().activeImageDownloads, 1);
  assert.equal((await app.request(`/api/room/${code}/latest`)).status, 503);
  const meta = await app.request(`/api/room/${code}/latest?meta=1`);
  assert.equal(meta.status, 200);
  await meta.arrayBuffer();
  response.destroy(); held.destroy();
  for (let i = 0; i < 200 && app.stats().activeImageDownloads; i++) await new Promise(resolve => setImmediate(resolve));
  assert.equal(app.stats().activeImageDownloads, 0);
});
