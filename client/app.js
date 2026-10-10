import { FileTransfers } from './transfer.js';

const $ = id => document.getElementById(id);
const config = window.NEARDROP_CONFIG || {};
const supported = !!(window.RTCPeerConnection && window.WebSocket && window.crypto?.randomUUID);
const store = {
  get(key) { try { return localStorage.getItem(`neardrop.${key}`); } catch { return null; } },
  set(key, value) { try { localStorage.setItem(`neardrop.${key}`, value); } catch { /* Private browsing can disable persistence. */ } },
};
const platform = /Android/i.test(navigator.userAgent) ? 'Android' : /Windows/i.test(navigator.userAgent) ? 'Windows' : 'Browser';
const settings = {
  name: store.get('name') || `${platform} · ${Math.floor(1000 + Math.random() * 9000)}`,
  url: new URLSearchParams(location.search).get('signal') || store.get('url') || config.signalingUrl,
};
let ws;
let selfId;
let registered = false;
let peers = new Map();
let session = null;
let incoming = null;
let reconnectTimer;
let retryDelay = 1000;
let signalQueue = Promise.resolve();
let renderFrame;
const transfers = new FileTransfers({
  maxIncomingBytes: config.maxIncomingBytes,
  onUpdate: () => { if (!renderFrame) renderFrame = requestAnimationFrame(() => { renderFrame = null; renderTransfers(); }); },
});

function notice(text) {
  $('notice').textContent = text;
  $('notice').hidden = !text;
}

function network(label, online = false) {
  $('network-status').replaceChildren(element('span', 'status-dot'), document.createTextNode(label));
  $('network-status').classList.toggle('online', online);
}

function element(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function send(message) {
  if (ws?.readyState !== WebSocket.OPEN) throw new Error('Signaling server is disconnected');
  ws.send(JSON.stringify(message));
}

function renderDevices() {
  $('self-name').textContent = settings.name;
  $('device-count').textContent = peers.size;
  $('devices-empty').hidden = peers.size > 0;
  $('refresh-button').disabled = !!session || !!incoming;
  const cards = [...peers.values()].map(peer => {
    const card = element('article', 'device-card');
    card.append(element('span', 'available', 'Available'), element('div', 'device-icon', /android|phone/i.test(peer.name) ? '▯' : '▱'));
    const title = element('div');
    title.append(element('h3', '', peer.name), element('p', '', 'Ready for a little handoff'));
    const button = element('button', 'button secondary', session?.peer.deviceId === peer.deviceId ? (session.ready ? 'Connected ✓' : 'Connecting…') : 'Connect ↗');
    button.disabled = !registered || !!session || !!incoming;
    button.addEventListener('click', () => requestConnection(peer));
    card.append(title, button);
    return card;
  });
  $('devices').replaceChildren(...cards);
  const ready = !!session?.ready;
  $('connection').hidden = !session;
  $('connection-title').textContent = session ? `${ready ? 'Connected to' : session.pc ? 'Establishing connection with' : 'Waiting for'} ${session.peer.name}` : '';
  $('connection-detail').textContent = ready ? 'Ready to share in both directions.' : session?.pc ? 'Creating your encrypted peer connection…' : 'Accept the connection on the other device.';
  $('disconnect-button').textContent = ready ? 'Disconnect' : 'Cancel';
  $('pick-button').disabled = !ready;
  $('drop-zone').setAttribute('aria-disabled', String(!ready));
  $('picker-help').textContent = ready ? `Choose a few files to send to ${session.peer.name}.` : 'Connect to a device to start sharing.';
}

function bytes(value) {
  if (value < 1024) return `${value} B`;
  const unit = Math.min(3, Math.floor(Math.log(value) / Math.log(1024)));
  return `${(value / 1024 ** unit).toFixed(unit > 1 ? 1 : 0)} ${['B', 'KiB', 'MiB', 'GiB'][unit]}`;
}

function renderTransfers() {
  for (const direction of ['outgoing', 'incoming']) {
    const records = [...transfers.records.values()].filter(record => record.direction === direction);
    $(`${direction}-count`).textContent = records.length;
    if (!records.length) {
      $(`${direction}-list`).replaceChildren(element('p', 'transfer-empty', direction === 'outgoing' ? 'Files you send will land here.' : 'A little room for something new.'));
      continue;
    }
    $(`${direction}-list`).replaceChildren(...records.map(record => {
      const row = element('article', `transfer-row${record.terminal && record.status !== 'Complete' ? ' failed' : ''}`);
      const top = element('div', 'transfer-top');
      const info = element('div', 'transfer-info');
      const name = element('span', 'file-name', record.name);
      name.title = record.name;
      info.append(name, element('span', 'file-meta', `${bytes(record.done)} / ${bytes(record.size)}`));
      top.append(element('span', 'file-icon', '▤'), info);
      if (record.url) {
        const save = element('a', 'transfer-action', 'Save ↓');
        save.href = record.url;
        save.download = record.name.replace(/[\\/\u0000-\u001f]/g, '_');
        save.setAttribute('aria-label', `Save ${record.name}`);
        top.append(save);
      } else if (!record.terminal) {
        const cancel = element('button', 'transfer-action', 'Cancel');
        cancel.setAttribute('aria-label', `Cancel ${record.name}`);
        cancel.addEventListener('click', () => transfers.cancel(record.id));
        top.append(cancel);
      }
      const track = element('div', 'progress-track');
      const fill = element('div', 'progress-fill');
      const percent = record.size ? Math.floor(record.done / record.size * 100) : record.status === 'Complete' ? 100 : 0;
      fill.style.width = `${percent}%`;
      track.setAttribute('role', 'progressbar');
      track.setAttribute('aria-label', record.name);
      track.setAttribute('aria-valuenow', percent);
      track.setAttribute('aria-valuemin', '0');
      track.setAttribute('aria-valuemax', '100');
      track.append(fill);
      row.append(top, track, element('p', 'transfer-status', record.status === 'Complete' && direction === 'incoming' ? 'Received · save a copy to your device' : record.status));
      return row;
    }));
  }
}

function validateURL(value) {
  const url = new URL(value);
  if (!['ws:', 'wss:'].includes(url.protocol)) throw new Error('Use a ws:// or wss:// signaling URL.');
  if (location.protocol === 'https:' && url.protocol !== 'wss:') throw new Error('An HTTPS page needs a secure wss:// signaling URL.');
  if (url.username || url.password || url.hash) throw new Error('The signaling URL cannot contain credentials or a fragment.');
  return url.href;
}

function connectSignaling() {
  if (!supported) {
    network('Unsupported browser');
    notice('Use a current Windows or Android browser over HTTPS (or localhost on this device) to enable secure file sharing.');
    return;
  }
  clearTimeout(reconnectTimer);
  const oldSocket = ws;
  ws = null;
  oldSocket?.close();
  registered = false;
  peers.clear();
  endSession(false);
  clearIncoming();
  renderDevices();
  let socket;
  try { socket = new WebSocket(validateURL(settings.url)); }
  catch (error) { network('Setup needed'); notice(error.message); return; }
  ws = socket;
  network('Connecting');
  const registrationTimer = setTimeout(() => { if (ws === socket && !registered) socket.close(); }, 12000);
  socket.addEventListener('open', () => {
    if (ws !== socket) return;
    send({ type: 'hello', name: settings.name });
  });
  socket.addEventListener('message', ({ data }) => {
    if (ws !== socket) return;
    // Serialize offer, answer, and ICE handling; addIceCandidate may be async.
    signalQueue = signalQueue.then(async () => {
      if (ws !== socket) return;
      let message;
      try {
        try { message = JSON.parse(data); } catch { throw new Error('The signaling server sent invalid JSON.'); }
        await handleMessage(message);
      } catch (error) {
        // A user may disconnect or replace a session during an awaited RTC call.
        if (ws !== socket || (message?.requestId && session?.id !== message.requestId)) return;
        notice(error.message || 'Connection failed. Please try again.');
        endSession(true);
      }
    });
  });
  socket.addEventListener('error', () => { if (ws === socket) notice('Cannot reach the signaling server. Check its address in connection settings.'); });
  socket.addEventListener('close', () => {
    clearTimeout(registrationTimer);
    if (ws !== socket) return;
    ws = null;
    registered = false;
    peers.clear();
    endSession(false);
    clearIncoming();
    renderDevices();
    network('Reconnecting');
    notice('Discovery disconnected. Reconnecting automatically…');
    reconnectTimer = setTimeout(connectSignaling, retryDelay);
    retryDelay = Math.min(retryDelay * 2, 15000);
  });
}

async function handleMessage(message) {
  if (!message || typeof message.type !== 'string') return;
  switch (message.type) {
    case 'ready':
      selfId = message.deviceId;
      peers = new Map((message.peers || []).filter(validPeer).filter(peer => peer.deviceId !== selfId).map(peer => [peer.deviceId, peer]));
      registered = true;
      retryDelay = 1000;
      network('Discoverable', true);
      notice('');
      renderDevices();
      break;
    case 'device.joined':
      if (validPeer(message.device) && message.device.deviceId !== selfId) peers.set(message.device.deviceId, message.device);
      renderDevices();
      break;
    case 'device.left':
      peers.delete(message.deviceId);
      if (incoming?.from.deviceId === message.deviceId) clearIncoming();
      if (session?.peer.deviceId === message.deviceId) { notice('The other device went offline.'); endSession(false); }
      renderDevices();
      break;
    case 'connect.pending':
      // The client supplied the ID; do not accept a mismatched server session.
      if (session && message.to === session.peer.deviceId && message.requestId !== session.id) throw new Error('The server returned an unexpected connection ID.');
      break;
    case 'connect.request':
      if (!validPeer(message.from) || typeof message.requestId !== 'string') return;
      if (session || incoming) { send({ type: 'connect.response', requestId: message.requestId, allow: false, reason: 'This device is busy. Try again shortly.' }); return; }
      incoming = message;
      incoming.timer = setTimeout(() => respondToRequest(false, 'Connection request expired.'), 45000);
      $('requester-name').textContent = message.from.name;
      $('approval-dialog').returnValue = '';
      $('approval-dialog').showModal();
      renderDevices();
      break;
    case 'connect.response': {
      const current = session;
      if (!current || current.id !== message.requestId || current.peer.deviceId !== message.from || current.pc) return;
      if (message.allow !== true) { notice(message.reason || 'Connection declined.'); endSession(false); return; }
      const pc = startPeer(current, true);
      await pc.setLocalDescription(await pc.createOffer());
      if (session !== current) return;
      sendSignal(current, { type: 'offer', sdp: pc.localDescription.sdp });
      break;
    }
    case 'signal': {
      const current = session;
      if (!current || current.id !== message.requestId || current.peer.deviceId !== message.from || !current.pc) return;
      const { signal } = message;
      const pc = current.pc;
      if (signal?.type === 'bye') { notice('The other device disconnected.'); endSession(false); return; }
      if (signal?.type === 'offer' && !current.initiator && !pc.remoteDescription) {
        await pc.setRemoteDescription({ type: 'offer', sdp: signal.sdp });
        if (session !== current) return;
        await flushCandidates(current);
        await pc.setLocalDescription(await pc.createAnswer());
        if (session !== current) return;
        sendSignal(current, { type: 'answer', sdp: pc.localDescription.sdp });
      } else if (signal?.type === 'answer' && current.initiator && pc.signalingState === 'have-local-offer') {
        await pc.setRemoteDescription({ type: 'answer', sdp: signal.sdp });
        if (session !== current) return;
        await flushCandidates(current);
      } else if (signal?.type === 'ice' && signal.candidate) {
        if (pc.remoteDescription) await pc.addIceCandidate(signal.candidate);
        else if (current.candidates.length < 256) current.candidates.push(signal.candidate);
      }
      break;
    }
    case 'error':
      notice(message.message || 'The signaling server rejected the request.');
      if (!message.requestId || session?.id === message.requestId) endSession(false);
      break;
  }
}

function validPeer(peer) {
  return peer && typeof peer.deviceId === 'string' && typeof peer.name === 'string';
}

function requestConnection(peer) {
  if (!registered || session || incoming) return;
  const current = { id: crypto.randomUUID(), peer, ready: false, candidates: [] };
  session = current;
  current.timer = setTimeout(() => {
    if (session !== current) return;
    connectSignaling(); // Registration restart also removes stale server requests.
    notice('No response yet. Check the other device and try again.');
  }, 50000);
  try { send({ type: 'connect.request', to: peer.deviceId, requestId: current.id }); notice(''); }
  catch (error) { notice(error.message); endSession(false); }
  renderDevices();
}

function clearIncoming() {
  if (incoming) clearTimeout(incoming.timer);
  incoming = null;
  if ($('approval-dialog').open) $('approval-dialog').close();
}

function respondToRequest(allow, reason = 'Connection declined.') {
  if (!incoming) return;
  const request = incoming;
  clearIncoming();
  try {
    if (allow) {
      session = { id: request.requestId, peer: request.from, ready: false, candidates: [] };
      startPeer(session, false);
    }
    send({ type: 'connect.response', requestId: request.requestId, allow, reason });
    notice('');
  } catch (error) { notice(error.message); endSession(false); }
  renderDevices();
}

function sendSignal(current, signal) {
  if (session === current) send({ type: 'signal', requestId: current.id, signal });
}

async function flushCandidates(current) {
  for (const candidate of current.candidates.splice(0)) {
    if (session !== current) return;
    await current.pc.addIceCandidate(candidate);
  }
}

function startPeer(current, initiator) {
  clearTimeout(current.timer);
  const pc = new RTCPeerConnection({ iceServers: config.iceServers || [] });
  current.pc = pc;
  current.initiator = initiator;
  current.timer = setTimeout(() => {
    if (session !== current || current.ready) return;
    notice('The peer connection timed out. Check your network or configure a TURN server.');
    endSession(true);
  }, 35000);
  pc.addEventListener('icecandidate', ({ candidate }) => {
    if (!candidate || session !== current) return;
    try { sendSignal(current, { type: 'ice', candidate: candidate.toJSON() }); }
    catch { endSession(false); }
  });
  pc.addEventListener('connectionstatechange', () => {
    if (session !== current) return;
    if (['failed', 'closed'].includes(pc.connectionState)) { notice('The peer connection ended. Connect again to retry.'); endSession(true); }
    if (pc.connectionState === 'disconnected') {
      clearTimeout(current.disconnectedTimer);
      current.disconnectedTimer = setTimeout(() => {
        if (session === current && pc.connectionState === 'disconnected') { notice('The other device is no longer reachable.'); endSession(true); }
      }, 10000);
    } else clearTimeout(current.disconnectedTimer);
  });
  pc.addEventListener('datachannel', ({ channel }) => {
    if (session !== current) { channel.close(); return; }
    if (channel.label === 'control' && !initiator && !current.control) bindControl(current, channel);
    else if (current.ready && channel.label.startsWith('file:')) transfers.receive(channel);
    else channel.close();
  });
  if (initiator) bindControl(current, pc.createDataChannel('control', { ordered: true }));
  renderDevices();
  return pc;
}

function bindControl(current, channel) {
  current.control = channel;
  const ready = () => {
    if (session !== current) return;
    clearTimeout(current.timer);
    current.ready = true;
    notice('');
    renderDevices();
  };
  channel.addEventListener('open', ready);
  if (channel.readyState === 'open') ready();
  channel.addEventListener('close', () => {
    if (session === current) { notice('The other device disconnected.'); endSession(false); }
  });
}

function endSession(notify) {
  const current = session;
  if (current && notify && current.pc) {
    try { sendSignal(current, { type: 'bye' }); } catch { /* Remote socket may have gone. */ }
  }
  session = null;
  if (current) {
    clearTimeout(current.timer);
    clearTimeout(current.disconnectedTimer);
    transfers.disconnect();
    current.pc?.close();
  }
  renderDevices();
}

function chooseFiles(files) {
  if (!session?.ready || !files.length) return;
  const active = [...transfers.records.values()].filter(record => record.direction === 'outgoing' && !record.terminal).length;
  if (files.length + active > 16) { notice('Send up to 16 files at a time. Wait for the current files to finish, then choose another batch.'); return; }
  notice('');
  for (const file of files) {
    try { transfers.send(session.pc, file); }
    catch (error) { notice(`Could not send ${file.name}: ${error.message}`); }
  }
}

function openSettings() {
  $('device-name').value = settings.name;
  $('signal-url').value = settings.url || '';
  $('settings-dialog').showModal();
}

$('settings-button').addEventListener('click', openSettings);
$('rename-button').addEventListener('click', openSettings);
$('settings-cancel').addEventListener('click', () => $('settings-dialog').close());
$('signal-url').addEventListener('input', () => $('signal-url').setCustomValidity(''));
$('settings-form').addEventListener('submit', event => {
  event.preventDefault();
  let url;
  try { url = validateURL($('signal-url').value.trim()); }
  catch (error) { $('signal-url').setCustomValidity(error.message); $('signal-url').reportValidity(); return; }
  const name = $('device-name').value.trim();
  if (!name) { $('device-name').value = ''; $('device-name').reportValidity(); return; }
  settings.name = name;
  settings.url = url;
  store.set('name', name);
  store.set('url', url);
  $('settings-dialog').close();
  connectSignaling();
});
$('approval-dialog').addEventListener('close', () => { if (incoming) respondToRequest($('approval-dialog').returnValue === 'accept'); });
$('refresh-button').addEventListener('click', connectSignaling);
$('disconnect-button').addEventListener('click', () => {
  if (session && !session.pc) connectSignaling();
  else endSession(true);
});
$('pick-button').addEventListener('click', () => $('file-input').click());
$('file-input').addEventListener('change', event => { chooseFiles([...event.target.files]); event.target.value = ''; });
$('clear-button').addEventListener('click', () => { transfers.clearFinished(); renderTransfers(); });
for (const name of ['dragenter', 'dragover']) $('drop-zone').addEventListener(name, event => { event.preventDefault(); if (session?.ready) $('drop-zone').classList.add('dragging'); });
for (const name of ['dragleave', 'drop']) $('drop-zone').addEventListener(name, event => { event.preventDefault(); $('drop-zone').classList.remove('dragging'); });
$('drop-zone').addEventListener('drop', event => chooseFiles([...event.dataTransfer.files]));
// Keep accidentally dropped files from navigating away from active transfers.
window.addEventListener('dragover', event => event.preventDefault());
window.addEventListener('drop', event => event.preventDefault());
window.addEventListener('beforeunload', event => {
  if ([...transfers.records.values()].some(record => !record.terminal || record.url)) { event.preventDefault(); event.returnValue = ''; }
});

renderDevices();
connectSignaling();
