'use strict';

const http = require('node:http');
const https = require('node:https');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { WebSocketServer, WebSocket } = require('ws');

const PORT = Number(process.env.PORT || 8787);
const HOST = process.env.HOST || '0.0.0.0';
const MAX_NAME_LENGTH = 80;
const MAX_ID_LENGTH = 96;
const MAX_PAYLOAD = 32 * 1024;

const devices = new Map();
const requests = new Map();

function send(socket, message) {
  if (socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify(message));
}

function error(socket, code, message, requestId) {
  send(socket, { type: 'error', code, message, ...(requestId ? { requestId } : {}) });
}

function text(value, fallback, maxLength) {
  if (typeof value !== 'string' || value.length === 0) return fallback;
  return value.slice(0, maxLength);
}

function publicDevice(device) {
  return { deviceId: device.id, name: device.name };
}

function broadcast(message, except) {
  for (const device of devices.values()) {
    if (device.socket !== except) send(device.socket, message);
  }
}

function removeDevice(device) {
  if (devices.get(device.id) !== device) return;
  devices.delete(device.id);
  for (const [requestId, request] of requests) {
    if (request.from === device.id || request.to === device.id) requests.delete(requestId);
  }
  broadcast({ type: 'device.left', deviceId: device.id });
}

function handleMessage(device, raw) {
  let message;
  try {
    message = JSON.parse(raw.toString());
  } catch {
    return error(device.socket, 'invalid_json', 'Message must be valid JSON.');
  }

  if (!message || typeof message.type !== 'string') {
    return error(device.socket, 'invalid_message', 'A message type is required.');
  }

  if (message.type === 'hello') {
    if (device.ready) return error(device.socket, 'already_registered', 'hello was already received.');
    const requestedId = text(message.deviceId, '', MAX_ID_LENGTH).replace(/[^a-zA-Z0-9._-]/g, '');
    let id = requestedId || crypto.randomUUID();
    if (devices.has(id)) id = crypto.randomUUID();
    device.id = id;
    device.name = text(message.name, 'Unnamed device', MAX_NAME_LENGTH);
    device.ready = true;
    devices.set(id, device);
    send(device.socket, {
      type: 'ready',
      deviceId: id,
      peers: [...devices.values()].filter((peer) => peer !== device).map(publicDevice)
    });
    broadcast({ type: 'device.joined', device: publicDevice(device) }, device.socket);
    return;
  }

  if (!device.ready) return error(device.socket, 'not_registered', 'Send hello before other messages.');

  if (message.type === 'connect.request') {
    const targetId = text(message.to, '', MAX_ID_LENGTH);
    const target = devices.get(targetId);
    if (!target || target === device) return error(device.socket, 'unknown_device', 'Target device is unavailable.');
    const requestId = text(message.requestId, crypto.randomUUID(), 64);
    if (requests.has(requestId)) return error(device.socket, 'duplicate_request', 'requestId is already in use.');
    requests.set(requestId, { from: device.id, to: target.id, approved: false });
    send(device.socket, { type: 'connect.pending', requestId, to: target.id });
    send(target.socket, {
      type: 'connect.request',
      requestId,
      from: publicDevice(device)
    });
    return;
  }

  if (message.type === 'connect.response') {
    const requestId = text(message.requestId, '', 64);
    const request = requests.get(requestId);
    if (!request || request.approved || request.to !== device.id) return error(device.socket, 'invalid_request', 'Unknown or unauthorized request.', requestId);
    if (typeof message.allow !== 'boolean') return error(device.socket, 'invalid_response', 'allow must be a boolean.', requestId);
    const requester = devices.get(request.from);
    if (message.allow) request.approved = true;
    else requests.delete(requestId);
    if (!requester) return;
    send(requester.socket, {
      type: 'connect.response',
      requestId,
      from: device.id,
      allow: message.allow === true,
      ...(message.allow === true ? {} : { reason: text(message.reason, 'Connection declined.', 160) })
    });
    return;
  }

  if (message.type === 'signal') {
    const requestId = text(message.requestId, '', 64);
    const request = requests.get(requestId);
    if (!request || !request.approved || (device.id !== request.from && device.id !== request.to)) {
      return error(device.socket, 'invalid_request', 'No approved connection for this request.', requestId);
    }
    const targetId = device.id === request.from ? request.to : request.from;
    const target = devices.get(targetId);
    if (!target || !message.signal || typeof message.signal !== 'object') {
      return error(device.socket, 'invalid_signal', 'signal must contain an object.', requestId);
    }
    // Relay only the WebRTC payload; the server never interprets SDP or ICE data.
    send(target.socket, { type: 'signal', requestId, from: device.id, signal: message.signal });
    return;
  }

  error(device.socket, 'unknown_type', `Unsupported message type: ${message.type}`);
}

// Explicit allowlist prevents serving workspace files or private configuration.
const assets = new Map([
  ['/', ['index.html', 'text/html']],
  ['/index.html', ['index.html', 'text/html']],
  ['/styles.css', ['styles.css', 'text/css']],
  ['/config.js', ['config.js', 'text/javascript']],
  ['/app.js', ['app.js', 'text/javascript']],
  ['/transfer.js', ['transfer.js', 'text/javascript']],
]);
function handleHttp(request, response) {
  response.setHeader('X-Content-Type-Options', 'nosniff');
  response.setHeader('Cache-Control', 'no-store');
  const pathname = new URL(request.url, 'http://localhost').pathname;
  const asset = assets.get(pathname);
  if (request.method === 'GET' && asset) {
    fs.readFile(path.join(__dirname, '..', 'client', asset[0]), (err, content) => {
      response.writeHead(err ? 500 : 200, { 'content-type': `${asset[1]}; charset=utf-8` });
      response.end(err ? 'Could not load the application.' : content);
    });
    return;
  }
  if (request.method === 'GET' && request.url === '/health') {
    response.writeHead(200, { 'content-type': 'application/json; charset=utf-8' });
    response.end(JSON.stringify({ ok: true, devices: devices.size }));
    return;
  }
  response.writeHead(404, { 'content-type': 'application/json; charset=utf-8' });
  response.end(JSON.stringify({ error: 'not_found' }));
}
const tlsEnabled = !!(process.env.TLS_CERT && process.env.TLS_KEY);
if (!!process.env.TLS_CERT !== !!process.env.TLS_KEY) {
  throw new Error('Set both TLS_CERT and TLS_KEY, or neither.');
}
const server = tlsEnabled ? https.createServer({
  cert: fs.readFileSync(process.env.TLS_CERT),
  key: fs.readFileSync(process.env.TLS_KEY),
}, handleHttp) : http.createServer(handleHttp);

const websocketServer = new WebSocketServer({ noServer: true, maxPayload: MAX_PAYLOAD });
websocketServer.on('connection', (socket) => {
  const device = { socket, id: null, name: null, ready: false };
  socket.isAlive = true;
  socket.on('pong', () => { socket.isAlive = true; });
  socket.on('message', (message, isBinary) => {
    if (isBinary) return error(socket, 'invalid_message', 'Send JSON text frames.');
    handleMessage(device, message);
  });
  socket.on('close', () => removeDevice(device));
  socket.on('error', () => removeDevice(device));
});

server.on('upgrade', (request, socket, head) => {
  let url;
  try {
    url = new URL(request.url, 'http://localhost');
  } catch {
    socket.destroy();
    return;
  }
  if (url.pathname !== '/ws') {
    socket.write('HTTP/1.1 404 Not Found\r\n\r\n');
    socket.destroy();
    return;
  }
  websocketServer.handleUpgrade(request, socket, head, (client) => websocketServer.emit('connection', client, request));
});

const heartbeat = setInterval(() => {
  for (const socket of websocketServer.clients) {
    if (!socket.isAlive) socket.terminate();
    else {
      socket.isAlive = false;
      socket.ping();
    }
  }
}, 30000);
heartbeat.unref();
websocketServer.on('close', () => clearInterval(heartbeat));

server.listen(PORT, HOST, () => console.log(`NearDrop listening on ${tlsEnabled ? 'https' : 'http'}://${HOST}:${PORT}`));
