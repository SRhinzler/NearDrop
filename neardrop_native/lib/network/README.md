# Native LAN transport

`lan_service.dart` uses only Dart SDK libraries. Start a service, subscribe to
`changes`, approve incoming requests through `onConnectionRequest`, and use
`connect`/`sendFile`. Missing approval callbacks decline connections. Transfer
directions are `send` and `receive`; statuses are `transferring`, `complete`, and
`failed`. `start(discovery: false)` and `bindHost: '127.0.0.1'` support isolated tests.

UDP IPv4 broadcast uses port 45873 and a `neardrop-1` JSON advertisement containing
only id, display name and ephemeral HTTP port. Announcements repeat every three
seconds and expire after twelve seconds. Networks/firewalls may block broadcast;
`discoverHost(host, port)` supplies manual connection support. Device IDs are
random per service instance, not permanent or authenticated device identities.

HTTP endpoints are GET `/identity`, POST `/connect`, POST `/upload?name=...`, and
POST `/disconnect`. Connection requests exchange separate 256-bit random bearer
capabilities for each direction after explicit approval. The inbound socket's
remote address, never a posted host, binds the session. Busy and simultaneous
cross-connection attempts fail with 409; neither is silently approved. Only one
peer is connected at a time, with up to two sends and two receives concurrently.
Metadata is capped at 16 KiB, advertisements at 4 KiB, and individual files at
1 TiB. Network operations have 30-second timeouts (stream reads use inactivity
timeouts). Transfers require Content-Length and validate the exact byte count.

Files stream to a random per-transfer directory inside the receive directory,
then rename from `.partial` when complete. Basenames are sanitized, collisions
cannot overwrite another transfer, and failures/disconnects delete partial
directories. Files are never opened or executed. Progress notifications are
throttled to approximately ten per second. Disconnect revokes local capabilities
immediately, cancels active receive readers and closes outgoing connections; it
also attempts to notify the remote peer. A crashed or unreachable remote peer
can require manual disconnect before reconnecting. Delivery acknowledgment loss
can leave the sender uncertain even if the recipient received the bytes.

**There is no transport encryption, authenticated identity, integrity hash, or
Internet-safe pairing.** HTTP exposes file contents and capability tokens to
network observers; UDP discovery is spoofable. Use only on a trusted LAN. Exact
size verification is not cryptographic content verification. Approval callbacks
cannot establish the genuine identity of a device. Do not expose the listener
through router port forwarding. Host firewall access may be necessary.

Run the loopback integration tests from the project directory:

```
flutter test test/network_test.dart
```
