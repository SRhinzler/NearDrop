# Same-network signaling server

This is the backend/signaling portion of a same-network file-sharing app. It does not store or transfer files: peers should use the approved WebRTC connection for that.

## Run

```sh
cd server
npm install
npm start
```

The server listens on `0.0.0.0:8787` by default. Set `PORT` and/or `HOST` to override it. The health check is `GET http://localhost:8787/health`; WebSocket clients connect to `ws://<server-host>:8787/ws`.

## Protocol

Messages are compact JSON objects. Every client must first send:

```json
{"type":"hello","deviceId":"optional-stable-id","name":"Laptop"}
```

The server replies with `ready` and a `peers` array, then broadcasts `device.joined` and `device.left` as devices appear or leave. Device records contain only `deviceId` and display `name`.

To request a connection, the initiator sends `connect.request` with `to` and an optional client-generated `requestId` (up to 64 characters). The initiator receives `connect.pending` with the authoritative `requestId` and `to`. The target receives the request plus the initiator's `from` device record. The target must answer:

```json
{"type":"connect.response","requestId":"...","allow":true}
```

An answer with `allow:false` may include a short `reason`. The response is forwarded to the initiator. Once approved, either peer can send WebRTC offer/answer/ICE payloads in:

```json
{"type":"signal","requestId":"...","signal":{"type":"offer","sdp":"..."}}
```

`signal` is relayed only between the two approved peers; the server does not inspect SDP or ICE contents. Relayed signals also contain `from` (the sender's device ID). `requestId` identifies the approved signaling session. Disconnecting either WebSocket removes its pending and approved sessions. Invalid JSON, unknown devices, and unauthorized request IDs receive an `error` message with `code` and `message`. Oversized payloads (over 32 KiB) close the WebSocket with code 1009. A heartbeat removes unreachable clients.

Discovery is a directory of clients connected to this server, not multicast LAN scanning. All clients must use the same server address. IDs are assigned by the server when omitted or already in use; always use the ID returned by `ready`. Reconnecting requires registration and fresh approval. The initiator should create the WebRTC offer after receiving approval; the receiver should wait for that offer. Pending requests remain until answered or either peer disconnects. State is held only in memory.

This server assumes the caller controls access to the local network. It has no authentication, encryption termination, file persistence, or TURN service; use HTTPS/WSS and an authentication layer if it is exposed beyond a trusted LAN.
