import http from 'node:http';
import crypto from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { extname, join, normalize } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('.', import.meta.url));
const publicDir = join(root, 'public');
const rooms = new Map();
const maxBytes = 8 * 1024 * 1024;
const ttlMs = 30 * 60 * 1000;
const sevenBuToken = process.env.SEVENBU_TOKEN?.trim();
const sevenBuAlbumId = process.env.SEVENBU_ALBUM_ID?.trim();
const mimeTypes = { '.css': 'text/css; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.html': 'text/html; charset=utf-8', '.json': 'application/json; charset=utf-8', '.svg': 'image/svg+xml' };

function code() {
  return String(crypto.randomInt(100000, 1000000));
}

function getRoom(id, create = false) {
  let room = rooms.get(id);
  if (!room && create) {
    room = { image: null, clients: new Set(), touched: Date.now() };
    rooms.set(id, room);
  }
  if (room) room.touched = Date.now();
  return room;
}

function sendJson(res, status, body) {
  const data = JSON.stringify(body);
  res.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' });
  res.end(data);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', chunk => {
      size += chunk.length;
      if (size > maxBytes) {
        reject(Object.assign(new Error('image too large'), { statusCode: 413 }));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

async function archiveToSevenBu(image, token) {
  if (!token) return { status: 'disabled' };
  const form = new FormData();
  form.append('file', new Blob([image.bytes], { type: image.mime }), 'pocket-clipboard.jpg');
  if (sevenBuAlbumId) form.append('album_id', sevenBuAlbumId);
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

function notifyImage(room) {
  const { data, ...metadata } = room.image;
  for (const client of room.clients) client.write(`event: image\ndata: ${JSON.stringify(metadata)}\n\n`);
}

async function serveStatic(req, res) {
  const pathname = new URL(req.url, `http://${req.headers.host}`).pathname;
  const requested = pathname === '/' ? '/index.html' : pathname;
  const file = normalize(join(publicDir, requested));
  if (!file.startsWith(publicDir)) return sendJson(res, 403, { error: 'forbidden' });
  try {
    const data = await readFile(file);
    res.writeHead(200, { 'content-type': mimeTypes[extname(file)] ?? 'application/octet-stream', 'cache-control': 'no-cache' });
    res.end(data);
  } catch {
    sendJson(res, 404, { error: 'not found' });
  }
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const parts = url.pathname.split('/').filter(Boolean);
  try {
    if (req.method === 'POST' && url.pathname === '/api/session') {
      let id = code();
      while (rooms.has(id)) id = code();
      getRoom(id, true);
      return sendJson(res, 201, { code: id });
    }
    if (parts[0] === 'api' && parts[1] === 'room' && parts[2]) {
      const id = parts[2].toUpperCase();
      const room = getRoom(id);
      if (!room) return sendJson(res, 404, { error: 'room expired' });
      if (req.method === 'POST' && parts[3] === 'image') {
        const mime = req.headers['content-type']?.split(';')[0] || 'image/jpeg';
        if (!mime.startsWith('image/')) return sendJson(res, 415, { error: 'image required' });
        const image = await readBody(req);
        const requestToken = req.headers['x-sevenbu-token']?.trim() || sevenBuToken;
        const imageAt = Date.now();
        room.image = { mime, data: image.toString('base64'), size: image.length, at: imageAt, hostedStatus: requestToken ? 'pending' : 'disabled', hostedUrl: null, hostedError: null };
        console.log(`[upload] room=${id} size=${image.length} mime=${mime}`);
        notifyImage(room);
        if (requestToken) {
          archiveToSevenBu({ bytes: image, mime }, requestToken).then(result => {
            if (!room.image || room.image.at !== imageAt) return;
            room.image.hostedStatus = result.status;
            room.image.hostedUrl = result.url;
            room.image.hostedError = null;
            room.touched = Date.now();
            console.log(`[7bu] room=${id} status=completed`);
            notifyImage(room);
          }).catch(error => {
            if (!room.image) return;
            room.image.hostedStatus = 'failed';
            room.image.hostedError = error.message;
            room.touched = Date.now();
            console.error(`[7bu] room=${id} status=failed error=${error.message}`);
            notifyImage(room);
          });
        }
        return sendJson(res, 201, { ok: true, size: image.length, hostedStatus: room.image.hostedStatus });
      }
      if (req.method === 'GET' && parts[3] === 'events') {
        res.writeHead(200, { 'content-type': 'text/event-stream; charset=utf-8', 'cache-control': 'no-cache', connection: 'keep-alive' });
        res.write(': connected\n\n');
        room.clients.add(res);
        req.on('close', () => room.clients.delete(res));
        return;
      }
      if (req.method === 'GET' && parts[3] === 'latest') {
        if (url.searchParams.has('meta') && room.image) {
          const { data, ...metadata } = room.image;
          return sendJson(res, 200, { image: metadata });
        }
        return sendJson(res, 200, { image: room.image });
      }
    }
    return serveStatic(req, res);
  } catch (error) {
    sendJson(res, error.statusCode || 500, { error: error.message || 'server error' });
  }
});

setInterval(() => {
  for (const [id, room] of rooms) if (Date.now() - room.touched > ttlMs && room.clients.size === 0) rooms.delete(id);
}, 60_000).unref();

const port = Number(process.env.PORT || 8787);
server.listen(port, '0.0.0.0', () => console.log(`Pocket Clipboard listening on http://localhost:${port}`));
