// One reliable, ordered data channel per file. Direction and file boundaries
// stay independent, including when both peers create channels simultaneously.
export const CHUNK_BYTES = 16 * 1024;
const HIGH_WATER = 256 * 1024;
const LOW_WATER = 64 * 1024;
const TIMEOUT = 60_000;

export class FileTransfers {
  constructor({ onUpdate, maxIncomingBytes = 256 * 1024 * 1024 }) {
    this.onUpdate = onUpdate;
    this.maxIncomingBytes = maxIncomingBytes;
    this.retainedBytes = 0;
    this.records = new Map();
  }

  update(record, status = record.status) {
    record.status = status;
    this.onUpdate(record);
  }

  create(direction, channel) {
    const id = crypto.randomUUID();
    const record = { id, direction, channel, name: 'Preparing file…', size: 0, done: 0, status: 'Preparing', terminal: false, chunks: [], url: null, reserved: 0 };
    this.records.set(id, record);
    channel.binaryType = 'arraybuffer';
    channel.bufferedAmountLowThreshold = LOW_WATER;
    channel.addEventListener('error', () => this.fail(record, 'Transfer interrupted'));
    channel.addEventListener('close', () => {
      if (!record.terminal) this.fail(record, 'Connection closed before completion');
    });
    this.touch(record);
    this.update(record);
    return record;
  }

  touch(record) {
    clearTimeout(record.timer);
    if (!record.terminal) record.timer = setTimeout(() => this.fail(record, 'Transfer timed out'), TIMEOUT);
  }

  fail(record, reason) {
    if (record.terminal) return;
    record.terminal = true;
    clearTimeout(record.timer);
    record.chunks = [];
    if (record.url) URL.revokeObjectURL(record.url);
    record.url = null;
    this.retainedBytes -= record.reserved;
    record.reserved = 0;
    this.update(record, reason);
    record.channel.close();
  }

  complete(record) {
    record.terminal = true;
    clearTimeout(record.timer);
    this.update(record, 'Complete');
  }

  send(pc, file) {
    const channel = pc.createDataChannel(`file:${crypto.randomUUID()}`, { ordered: true });
    const record = this.create('outgoing', channel);
    Object.assign(record, { name: file.name, size: file.size });
    this.update(record, 'Waiting for receiver');
    let started = false;
    let finishedSending = false;
    channel.addEventListener('open', () => {
      try { channel.send(JSON.stringify({ type: 'meta', name: file.name, size: file.size, mime: file.type })); }
      catch { this.fail(record, 'Could not start transfer'); }
    });
    channel.addEventListener('message', async ({ data }) => {
      if (record.terminal) return;
      try {
        if (typeof data !== 'string') throw new Error('Unexpected binary response');
        const message = JSON.parse(data);
        if (message.type === 'ready' && !started) {
          started = true;
          this.touch(record);
          this.update(record, 'Sending');
          // A conservative payload fits the mandatory WebRTC message size.
          const chunkSize = Math.min(CHUNK_BYTES, pc.sctp?.maxMessageSize || CHUNK_BYTES);
          for (let offset = 0; offset < file.size; offset += chunkSize) {
            await this.waitForBuffer(record);
            const chunk = await file.slice(offset, offset + chunkSize).arrayBuffer();
            if (record.terminal || channel.readyState !== 'open') return;
            channel.send(chunk);
            record.done += chunk.byteLength;
            this.touch(record);
            this.update(record, 'Sending');
          }
          await this.waitForBuffer(record);
          if (record.terminal) return;
          finishedSending = true;
          channel.send(JSON.stringify({ type: 'end' }));
          this.touch(record);
          this.update(record, 'Waiting for receipt');
        } else if (message.type === 'complete' && finishedSending && message.size === record.size) {
          this.complete(record);
          channel.close();
        } else if (message.type === 'reject') {
          this.fail(record, String(message.reason || 'Receiver declined file').slice(0, 140));
        } else throw new Error('Invalid transfer response');
      } catch (error) { this.fail(record, error.message || 'File could not be sent'); }
    });
    return record;
  }

  waitForBuffer(record) {
    const channel = record.channel;
    if (record.terminal || channel.readyState !== 'open') return Promise.reject(new Error('Transfer stopped'));
    if (channel.bufferedAmount <= HIGH_WATER) return Promise.resolve();
    return new Promise((resolve, reject) => {
      const cleanup = () => {
        channel.removeEventListener('bufferedamountlow', ready);
        channel.removeEventListener('close', closed);
        channel.removeEventListener('error', closed);
      };
      const ready = () => { cleanup(); resolve(); };
      const closed = () => { cleanup(); reject(new Error('Transfer stopped')); };
      channel.addEventListener('bufferedamountlow', ready, { once: true });
      channel.addEventListener('close', closed, { once: true });
      channel.addEventListener('error', closed, { once: true });
    });
  }

  receive(channel) {
    if (!channel.label.startsWith('file:') || !channel.ordered || channel.maxRetransmits !== null || channel.maxPacketLifeTime !== null) {
      channel.close();
      return;
    }
    // Bound active incoming channels as well as the total retained payload.
    if ([...this.records.values()].filter(r => r.direction === 'incoming' && !r.terminal).length >= 16) {
      channel.close();
      return;
    }
    const record = this.create('incoming', channel);
    let hasMeta = false;
    channel.addEventListener('message', ({ data }) => {
      if (record.terminal) return;
      try {
        this.touch(record);
        if (typeof data === 'string') {
          if (data.length > 4096) throw new Error('Invalid file metadata');
          const message = JSON.parse(data);
          if (message.type === 'meta' && !hasMeta) {
            if (typeof message.name !== 'string' || !message.name || message.name.length > 255 || !Number.isSafeInteger(message.size) || message.size < 0) throw new Error('Invalid file metadata');
            record.name = message.name;
            record.size = message.size;
            if (message.size > this.maxIncomingBytes - this.retainedBytes) throw new Error('Receiver memory limit reached; clear finished files');
            record.reserved = message.size;
            this.retainedBytes += message.size;
            hasMeta = true;
            channel.send(JSON.stringify({ type: 'ready' }));
            this.update(record, 'Receiving');
          } else if (message.type === 'end' && hasMeta && record.done === record.size) {
            // Download as opaque bytes. Never render incoming HTML or execute files.
            const blob = new Blob(record.chunks, { type: 'application/octet-stream' });
            record.chunks = [];
            record.url = URL.createObjectURL(blob);
            channel.send(JSON.stringify({ type: 'complete', size: record.done }));
            this.complete(record);
            // Sender closes after receiving the receipt.
          } else throw new Error('Invalid or incomplete transfer');
        } else if (data instanceof ArrayBuffer && hasMeta && data.byteLength > 0 && data.byteLength <= CHUNK_BYTES && record.done + data.byteLength <= record.size) {
          record.chunks.push(data);
          record.done += data.byteLength;
          this.update(record, 'Receiving');
        } else throw new Error('Invalid file chunk');
      } catch (error) {
        try { channel.send(JSON.stringify({ type: 'reject', reason: error.message })); } catch { /* Channel may already be closed. */ }
        this.fail(record, error.message || 'File could not be received');
      }
    });
    return record;
  }

  cancel(id) {
    const record = this.records.get(id);
    if (record) this.fail(record, 'Canceled');
  }

  disconnect() {
    for (const record of this.records.values()) {
      if (!record.terminal) this.fail(record, 'Connection ended');
      else record.channel.close();
    }
  }

  clearFinished() {
    for (const [id, record] of this.records) {
      if (!record.terminal) continue;
      if (record.url) URL.revokeObjectURL(record.url);
      this.retainedBytes -= record.reserved;
      record.reserved = 0;
      record.channel.close();
      this.records.delete(id);
    }
  }
}
