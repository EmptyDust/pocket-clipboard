import http from 'node:http';
import crypto from 'node:crypto';
import { createReadStream } from 'node:fs';
import { stat } from 'node:fs/promises';
import { pipeline } from 'node:stream/promises';
import { Readable } from 'node:stream';
import { extname, resolve, sep } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = fileURLToPath(new URL('.', import.meta.url));
const mimeTypes = { '.css': 'text/css; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.html': 'text/html; charset=utf-8', '.json': 'application/json; charset=utf-8', '.svg': 'image/svg+xml', '.zip': 'application/zip', '.apk': 'application/vnd.android.package-archive' };

async function archiveToSevenBu(image, token) {
  const form = new FormData();
  form.append('file', new Blob([image.bytes], { type: image.mime }), 'pocket-clipboard.jpg');
  const album = process.env.SEVENBU_ALBUM_ID?.trim();
  if (album) form.append('album_id', album);
  const response = await fetch('https://7bu.top/api/v1/upload', {
    method: 'POST',
    headers: { Authorization: token.startsWith('Bearer ') ? token : `Bearer ${token}`, Accept: 'application/json' },
    body: form,
    signal: AbortSignal.timeout(30_000)
  });
  const body = await response.json().catch(() => ({}));
  const url = body?.data?.links?.url;
  if (!response.ok || !url) throw new Error(body?.message || `7bu returned ${response.status}`);
  return { status: 'completed', url };
}

export function createRelayServer(options = {}) {
  const now = options.now ?? Date.now;
  const ttlMs = options.ttlMs ?? 30 * 60_000;
  const maxBytes = options.maxBytes ?? 8 * 1024 * 1024;
  const maxRetainedBytes = options.maxRetainedBytes ?? 64 * 1024 * 1024;
  const maxRooms = options.maxRooms ?? 512;
  const maxUploads = options.maxUploads ?? 4;
  const maxArchives = options.maxArchives ?? 4;
  const maxClients = options.maxClients ?? 128;
  const maxRoomClients = options.maxRoomClients ?? 8;
  const maxImageDownloads = options.maxImageDownloads ?? 8;
  const publicDir = resolve(options.publicDir ?? resolve(root, 'public'));
  const archive = options.archive ?? archiveToSevenBu;
  const fallbackToken = options.fallbackToken ?? process.env.SEVENBU_TOKEN?.trim();
  const rooms = new Map();
  let retainedBytes = 0;
  let activeUploads = 0;
  let activeArchives = 0;
  let clients = 0;
  let activeImageDownloads = 0;

  function json(res, status, body, headers = {}) {
    const data = Buffer.from(JSON.stringify(body));
    res.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store', 'content-length': data.length, ...headers });
    res.end(data);
  }

  function updateMetadata(room) {
    room.metaBody = Buffer.from(JSON.stringify({ image: room.image }));
    room.etag = `"${crypto.createHash('sha256').update(room.metaBody).digest('hex')}"`;
    // Re-encode only the small metadata when the archive status changes.
    room.fullPrefix = room.image ? Buffer.from(`{"image":{${JSON.stringify(room.image).slice(1, -1)},"data":"`) : null;
  }

  function dropImage(room) {
    retainedBytes -= room.data?.length ?? 0;
    room.data = null;
    room.image = null;
    updateMetadata(room);
  }

  function sweep() {
    for (const [id, room] of rooms) {
      // Polling keeps a pairing alive, but must not retain old image bytes forever.
      if (room.image && now() - room.image.at >= ttlMs) dropImage(room);
      if (now() - room.touched >= ttlMs && room.clients.size === 0 && room.uploads === 0) {
        dropImage(room);
        rooms.delete(id);
      }
    }
  }

  function writeEvent(client, event) {
    if (client.destroyed || !client.write(event)) client.destroy();
  }

  function notify(room) {
    const event = `event: image\ndata: ${JSON.stringify(room.image)}\n\n`;
    for (const client of room.clients) writeEvent(client, event);
  }

  async function readBody(req) {
    const length = Number(req.headers['content-length']);
    if (length > maxBytes) {
      req.resume();
      throw Object.assign(new Error('image too large'), { statusCode: 413 });
    }
    const chunks = [];
    let size = 0;
    for await (const chunk of req) {
      size += chunk.length;
      if (size > maxBytes) throw Object.assign(new Error('image too large'), { statusCode: 413 });
      chunks.push(chunk);
    }
    return Buffer.concat(chunks, size);
  }

  async function serveStatic(req, res, pathname) {
    if (req.method !== 'GET' && req.method !== 'HEAD') return json(res, 405, { error: 'method not allowed' });
    const file = resolve(publicDir, `.${pathname === '/' ? '/index.html' : decodeURIComponent(pathname)}`);
    if (!file.startsWith(publicDir + sep)) return json(res, 403, { error: 'forbidden' });
    let info;
    try { info = await stat(file); } catch { return json(res, 404, { error: 'not found' }); }
    if (!info.isFile()) return json(res, 404, { error: 'not found' });
    res.writeHead(200, { 'content-type': mimeTypes[extname(file)] ?? 'application/octet-stream', 'content-length': info.size, 'cache-control': 'no-cache' });
    if (req.method === 'HEAD') return res.end();
    // A slow download retains stream buffers instead of a complete APK/ZIP.
    await pipeline(createReadStream(file), res);
  }

  const server = http.createServer(async (req, res) => {
    try {
      const url = new URL(req.url, 'http://localhost');
      const parts = url.pathname.split('/').filter(Boolean);
      if (req.method === 'POST' && url.pathname === '/api/session') {
        sweep();
        if (rooms.size >= maxRooms) return json(res, 503, { error: 'room capacity reached' });
        let id;
        do { id = String(crypto.randomInt(100000, 1000000)); } while (rooms.has(id));
        const room = { image: null, data: null, clients: new Set(), touched: now(), uploads: 0 };
        updateMetadata(room);
        rooms.set(id, room);
        return json(res, 201, { code: id });
      }
      if (parts[0] === 'api' && parts[1] === 'room' && /^\d{6}$/.test(parts[2] ?? '')) {
        sweep();
        const id = parts[2];
        const room = rooms.get(id);
        if (!room) return json(res, 404, { error: 'room expired' });
        room.touched = now();
        if (req.method === 'POST' && parts[3] === 'image') {
          const mime = req.headers['content-type']?.split(';')[0] || 'image/jpeg';
          if (!mime.startsWith('image/')) { req.resume(); return json(res, 415, { error: 'image required' }); }
          if (activeUploads >= maxUploads) { req.resume(); return json(res, 503, { error: 'upload capacity reached' }); }
          activeUploads++;
          room.uploads++;
          try {
            const image = await readBody(req);
            if (!image.length) return json(res, 400, { error: 'empty image' });
            const encodedSize = 4 * Math.ceil(image.length / 3);
            if (retainedBytes - (room.data?.length ?? 0) + encodedSize > maxRetainedBytes) {
              return json(res, 503, { error: 'image memory capacity reached' });
            }
            const token = req.headers['x-sevenbu-token']?.trim() || fallbackToken;
            const archiveBusy = Boolean(token) && activeArchives >= maxArchives;
            const imageAt = Math.max(now(), (room.image?.at ?? 0) + 1);
            dropImage(room);
            room.data = Buffer.from(image.toString('base64'));
            retainedBytes += room.data.length;
            room.image = { mime, size: image.length, at: imageAt, hostedStatus: token ? (archiveBusy ? 'failed' : 'pending') : 'disabled', hostedUrl: null, hostedError: archiveBusy ? 'archive capacity reached' : null };
            updateMetadata(room);
            notify(room);
            console.log(`[upload] room=${id} size=${image.length} mime=${mime}`);
            if (token && !archiveBusy) {
              activeArchives++;
              Promise.resolve().then(() => archive({ bytes: image, mime }, token)).then(result => {
                if (rooms.get(id) !== room || room.image?.at !== imageAt) return;
                room.image.hostedStatus = result.status;
                room.image.hostedUrl = result.url ?? null;
                room.image.hostedError = null;
                updateMetadata(room);
                notify(room);
              }).catch(error => {
                // An older failed archive must not overwrite a newer image's status.
                if (rooms.get(id) !== room || room.image?.at !== imageAt) return;
                room.image.hostedStatus = 'failed';
                room.image.hostedError = String(error.message).slice(0, 512);
                updateMetadata(room);
                notify(room);
              }).finally(() => { activeArchives--; });
            }
            return json(res, 201, { ok: true, size: image.length, hostedStatus: room.image.hostedStatus });
          } finally {
            activeUploads--;
            room.uploads--;
          }
        }
        if (req.method === 'GET' && parts[3] === 'events') {
          if (clients >= maxClients || room.clients.size >= maxRoomClients) return json(res, 503, { error: 'event connection capacity reached' });
          res.writeHead(200, { 'content-type': 'text/event-stream; charset=utf-8', 'cache-control': 'no-cache', connection: 'keep-alive', 'x-accel-buffering': 'no' });
          res.write(': connected\n\n');
          room.clients.add(res);
          clients++;
          res.once('close', () => { if (room.clients.delete(res)) clients--; });
          return;
        }
        if (req.method === 'GET' && parts[3] === 'latest') {
          const meta = url.searchParams.has('meta');
          if (meta && req.headers['if-none-match'] === room.etag) {
            res.writeHead(304, { etag: room.etag, 'cache-control': 'no-store' });
            return res.end();
          }
          const headers = { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store', etag: room.etag };
          if (meta || !room.image) {
            res.writeHead(200, { ...headers, 'content-length': room.metaBody.length });
            return res.end(room.metaBody);
          }
          if (activeImageDownloads >= maxImageDownloads) return json(res, 503, { error: 'image download capacity reached' });
          activeImageDownloads++;
          try {
            res.writeHead(200, { ...headers, 'content-length': room.fullPrefix.length + room.data.length + 3 });
            await pipeline(Readable.from([room.fullPrefix, room.data, Buffer.from('"}}')]), res);
          } finally { activeImageDownloads--; }
          return;
        }
        return json(res, 404, { error: 'not found' });
      }
      await serveStatic(req, res, url.pathname);
    } catch (error) {
      if (res.destroyed) return;
      if (res.headersSent) { res.destroy(); return; }
      json(res, error.statusCode || 500, { error: error.message || 'server error' });
    }
  });
  server.requestTimeout = 60_000;
  server.headersTimeout = 15_000;
  server.maxConnections = 256;
  const maintenance = setInterval(() => {
    sweep();
    for (const room of rooms.values()) for (const client of room.clients) writeEvent(client, ': ping\n\n');
  }, 25_000).unref();
  server.on('close', () => clearInterval(maintenance));
  return { server, sweep, stats: () => ({ rooms: rooms.size, retainedBytes, activeUploads, activeArchives, clients, activeImageDownloads }) };
}

if (process.argv[1] && pathToFileURL(resolve(process.argv[1])).href === import.meta.url) {
  const { server } = createRelayServer();
  const port = Number(process.env.PORT || 8787);
  server.listen(port, process.env.HOST || '0.0.0.0', () => console.log(`Pocket Clipboard listening on port ${port}`));
}
