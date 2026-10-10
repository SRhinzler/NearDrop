# NearDrop browser client

A dependency-free static client for Windows and Android browsers, with device discovery, explicit connection approval, direct WebRTC file sharing, per-file progress/cancel controls, and downloadable received files. Files can travel in both directions simultaneously. This folder contains no server implementation.

## Hosting and configuration

Serve this folder with any static web server. Open `index.html` through **HTTPS**, or `http://localhost` on the same device. Do not open it as a `file://` URL: ES modules require an HTTP origin. Android needs a trusted HTTPS origin when accessing a host on another computer; plain `http://192.168.x.x` does not provide all required secure-context APIs.

Edit `config.js` before hosting:

- `signalingUrl`: WebSocket URL for the signaling server, such as `wss://share.example.com/ws`. The default is `/ws` on the page's host, intended for a reverse proxy. The companion server's standalone default endpoint is `ws://localhost:8787/ws` for local testing; change the URL in **Connection settings** if the static host uses a different port. HTTPS pages require WSS.
- `iceServers`: `RTCIceServer[]`, default `[]` for same-network host candidates. Set STUN/TURN servers as needed for other networks. TURN credentials should be short-lived credentials obtained by your deployment, not permanent secrets published in this file.
- `maxIncomingBytes`: total bytes reserved for active and completed incoming files, default 256 MiB. Clear finished transfers to release received blobs. The UI's helper text describes this default; update it if changing the limit.

The gear icon opens connection settings; the endpoint and display name are saved locally when storage is available. `?signal=wss%3A%2F%2Fhost%2Fws` overrides the saved/default endpoint on page load. Saving settings reconnects discovery and ends an active peer connection. The font stylesheet uses Google Fonts with system-font fallbacks; the app remains usable without the font service.

## Signaling protocol

The client matches the companion `server/server.js` protocol. All messages are JSON text WebSocket frames. “Nearby” means registered with this signaling server, **not** automatic LAN multicast discovery. Each socket is one device; the server assigns its current ID. Device names are presentation only.

### Register and discover

Client sends:

```json
{"type":"hello","name":"Windows · 1234"}
```

Server responds and broadcasts subsequent presence changes:

```json
{"type":"ready","deviceId":"a","peers":[{"deviceId":"b","name":"Android · 5678"}]}
{"type":"device.joined","device":{"deviceId":"b","name":"Android · 5678"}}
{"type":"device.left","deviceId":"b"}
```

### Request and approval

Requester generates a unique request ID and sends:

```json
{"type":"connect.request","to":"b","requestId":"uuid"}
```

Requester receives `{ "type":"connect.pending", "requestId":"uuid", "to":"b" }`.
Receiver gets `{ "type":"connect.request", "requestId":"uuid", "from":{ "deviceId":"a", "name":"Windows · 1234" } }` and displays an approval dialog.

Receiver sends `{ "type":"connect.response", "requestId":"uuid", "allow":true }` or `allow:false` with an optional `reason`. Requester receives the same response with `from:"b"`. This client allows one peer connection at a time and declines additional incoming requests while busy. The receiver creates a peer connection before sending approval; the requester creates the sole initial SDP offer after approval. An unanswered dialog expires after 45 seconds; a requester times out after 50 seconds and re-registers to remove the stale server request.

### WebRTC signaling

Either approved peer sends:

```json
{"type":"signal","requestId":"uuid","signal":{"type":"offer","sdp":"..."}}
{"type":"signal","requestId":"uuid","signal":{"type":"answer","sdp":"..."}}
{"type":"signal","requestId":"uuid","signal":{"type":"ice","candidate":{"candidate":"...","sdpMid":"0","sdpMLineIndex":0}}}
{"type":"signal","requestId":"uuid","signal":{"type":"bye"}}
```

The server forwards the envelope with the sender's device ID in `from`. `bye` is a client-level teardown message carried in the same approved relay; the server need not interpret it. The client checks session ID and sender, queues ICE until remote SDP is set, and ignores stale messages. The initial offer contains a reliable ordered `control` data channel, which establishes SCTP before any files are selected. Subsequent file channels require no additional SDP negotiation.

Errors use `{ "type":"error", "code":"...", "message":"...", "requestId":"optional" }`. The server must authorize signaling against the approved request, supply trustworthy sender IDs, and remove sessions on WebSocket disconnect. Refresh reconnects the directory only when idle. Losing signaling tears down active peer state; reconnects use bounded exponential backoff (1–15 seconds) and require fresh approval. A 12-second registration timeout also handles a stalled signaling handshake.

## File data-channel protocol

Files are never sent over the signaling WebSocket. Each sender creates one **reliable, ordered** RTCDataChannel with label `file:<unique-id>` for each file. A maximum of 16 active files may be sent or received per direction. Multiple independent channels prevent framing collisions during simultaneous bidirectional transfers.

1. Sender sends a JSON text frame `{ "type":"meta", "name":"photo.jpg", "size":1234, "mime":"image/jpeg" }`.
2. Receiver validates metadata and reserves the declared size against its aggregate memory limit. It replies `{ "type":"ready" }`, or `{ "type":"reject", "reason":"..." }` then closes the channel.
3. Sender streams `ArrayBuffer` binary frames of at most 16 KiB. The receiver counts exact bytes and rejects overflow. Sender pauses when its channel's `bufferedAmount` exceeds 256 KiB and resumes at 64 KiB. File slices are read incrementally; the outgoing file is not loaded wholesale into memory.
4. Sender sends `{ "type":"end" }` after all bytes. A zero-byte file still follows the metadata/ready/end sequence.
5. Receiver verifies the exact declared length, builds an opaque downloadable Blob, and replies `{ "type":"complete", "size":1234 }`. Sender marks completion only on this receipt and closes the channel.

Downloads require the receiver to select **Save** for each file, avoiding browser restrictions on automatic multiple downloads. Untrusted file names are rendered using text nodes; download names have path separators/control characters removed. File contents are not previewed or executed. **Clear finished** revokes object URLs and releases their memory reservations. Received files are held only in browser memory, and are lost on reload/closing the page unless saved.

Cancel closes only the selected channel. Both sides mark an unexpectedly closed channel as failed. Transfers time out after 60 seconds without progress; connection establishment times out after 35 seconds. Temporary peer disconnects get a 10-second recovery window. Completed incoming files remain available after disconnect until cleared/reloaded. No resume, directory recursion, disk streaming, or content hash is implemented. WebRTC provides encrypted reliable transport; exact byte counts detect truncated transfers.

## Verification

Use Node.js 22 or later. Run `node --test client/transfer.test.mjs` from the project root for the transfer protocol checks (using paired in-memory data channels). Syntax checks: `node --check client/app.js`, `node --check client/transfer.js`, and `node --check client/config.js`. From this folder, `npm test` and `npm run check` run the same checks; no dependency installation is needed.

Real-device acceptance check:

1. Open this client on Windows and Android against the same signaling endpoint. Both devices appear; custom names render correctly.
2. Request a connection. Decline once, then request again and approve on the other device.
3. Send a zero-byte file, several files, and a larger file. While a large file is sending, send files back from the other device. Save each received file and compare bytes/hashes with the originals.
4. Cancel one transfer while another continues; disconnect mid-transfer and confirm active transfers fail without a false completion. Reconnect and transfer again.
5. Clear finished files to reclaim the incoming allowance; test a file over that allowance and check rejection. Close one device to verify presence cleanup.

The automated transfer tests are not a replacement for a two-browser WebRTC/ICE test. HTTPS certificates, network isolation, TURN configuration, Android background suspension, and browser download behavior need validation in the deployment environment. Keep both pages in the foreground during transfers.
