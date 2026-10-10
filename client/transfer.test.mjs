import test from 'node:test';
import assert from 'node:assert/strict';
import { FileTransfers } from './transfer.js';

class Channel extends EventTarget {
  constructor(label) {
    super();
    Object.assign(this, { label, ordered: true, maxRetransmits: null, maxPacketLifeTime: null, readyState: 'connecting', bufferedAmount: 0, bufferedAmountLowThreshold: 0 });
  }
  send(data) {
    if (this.readyState !== 'open') throw new Error('Channel not open');
    const copy = typeof data === 'string' ? data : data.slice(0);
    queueMicrotask(() => {
      if (this.other.readyState === 'open') this.other.dispatchEvent(new MessageEvent('message', { data: copy }));
    });
  }
  close() {
    for (const channel of [this, this.other]) {
      if (channel.readyState === 'closed') continue;
      channel.readyState = 'closed';
      queueMicrotask(() => channel.dispatchEvent(new Event('close')));
    }
  }
}

function pair(label = 'file:test') {
  const a = new Channel(label);
  const b = new Channel(label);
  a.other = b;
  b.other = a;
  return [a, b];
}

function open(channels) {
  for (const channel of channels) channel.readyState = 'open';
  for (const channel of channels) channel.dispatchEvent(new Event('open'));
}

function peer(receiver) {
  return {
    sctp: { maxMessageSize: 65536 },
    createDataChannel(label) {
      const channels = pair(label);
      receiver.receive(channels[1]);
      queueMicrotask(() => open(channels));
      return channels[0];
    },
  };
}

function engine(t, maxIncomingBytes) {
  const value = new FileTransfers({ onUpdate: () => {}, maxIncomingBytes });
  t.after(() => { value.disconnect(); value.clearFinished(); });
  return value;
}

async function until(predicate) {
  const end = Date.now() + 3000;
  while (!predicate()) {
    if (Date.now() > end) throw new Error('Timed out waiting for transfer');
    await new Promise(resolve => setTimeout(resolve, 5));
  }
}

test('multiple simultaneous bidirectional files preserve exact bytes and receipts', async t => {
  const a = engine(t);
  const b = engine(t);
  const payloadA = new Uint8Array(170_003).map((_, index) => index % 251);
  const payloadB = new Uint8Array(221_037).map((_, index) => (index * 7) % 253);
  const outA = a.send(peer(b), new File([payloadA], 'from-a.bin'));
  const outA2 = a.send(peer(b), new File(['another file'], 'second.txt'));
  const outB = b.send(peer(a), new File([payloadB], 'from-b.bin'));
  await until(() => [outA, outA2, outB].every(record => record.terminal));
  assert.deepEqual([outA, outA2, outB].map(record => record.status), ['Complete', 'Complete', 'Complete']);
  const inA = [...a.records.values()].find(record => record.direction === 'incoming');
  const inB = [...b.records.values()].find(record => record.name === 'from-a.bin');
  assert.deepEqual(new Uint8Array(await (await fetch(inA.url)).arrayBuffer()), payloadB);
  assert.deepEqual(new Uint8Array(await (await fetch(inB.url)).arrayBuffer()), payloadA);
  assert.equal(a.retainedBytes, payloadB.length);
  b.clearFinished();
  assert.equal(b.retainedBytes, 0);
});

test('zero-byte files complete with a usable empty download', async t => {
  const a = engine(t);
  const b = engine(t);
  const sent = a.send(peer(b), new File([], 'empty.txt'));
  await until(() => sent.terminal);
  assert.equal(sent.status, 'Complete');
  const received = [...b.records.values()][0];
  assert.equal((await (await fetch(received.url)).arrayBuffer()).byteLength, 0);
});

test('receiver enforces aggregate retained-byte limit and reclaims it on clear', async t => {
  const a = engine(t);
  const b = engine(t, 6);
  const first = a.send(peer(b), new File(['12345'], 'first.txt'));
  await until(() => first.terminal);
  const second = a.send(peer(b), new File(['ab'], 'second.txt'));
  await until(() => second.terminal);
  assert.notEqual(second.status, 'Complete');
  assert.equal(b.retainedBytes, 5);
  b.clearFinished();
  const retry = a.send(peer(b), new File(['ab'], 'second.txt'));
  await until(() => retry.terminal);
  assert.equal(retry.status, 'Complete');
});

test('truncated content fails rather than producing a completed download', async t => {
  const b = engine(t);
  const channels = pair();
  const received = b.receive(channels[1]);
  open(channels);
  channels[0].send(JSON.stringify({ type: 'meta', name: 'broken.bin', size: 9 }));
  channels[0].send(new Uint8Array([1, 2]).buffer);
  channels[0].send(JSON.stringify({ type: 'end' }));
  await until(() => received.terminal);
  assert.equal(received.url, null);
  assert.notEqual(received.status, 'Complete');
  assert.equal(b.retainedBytes, 0);
});

test('canceling a receiving channel frees its reservation without completing it', async t => {
  const b = engine(t);
  const channels = pair();
  const received = b.receive(channels[1]);
  open(channels);
  channels[0].send(JSON.stringify({ type: 'meta', name: 'cancel.bin', size: 20 }));
  await until(() => received.status === 'Receiving');
  b.cancel(received.id);
  assert.equal(received.status, 'Canceled');
  assert.equal(b.retainedBytes, 0);
  assert.equal(channels[0].readyState, 'closed');
});

test('backpressure waits for a low-buffer event and rejects on channel close', async t => {
  const a = engine(t);
  const channels = pair();
  open(channels);
  const record = a.create('outgoing', channels[0]);
  channels[0].bufferedAmount = 300_000;
  let resumed = false;
  const waiting = a.waitForBuffer(record).then(() => { resumed = true; });
  await Promise.resolve();
  assert.equal(resumed, false);
  channels[0].bufferedAmount = 0;
  channels[0].dispatchEvent(new Event('bufferedamountlow'));
  await waiting;
  assert.equal(resumed, true);
  channels[0].bufferedAmount = 300_000;
  const interrupted = a.waitForBuffer(record);
  channels[0].close();
  await assert.rejects(interrupted, /Transfer stopped/);
});
