import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

class Peer {
  final String id, name, host;
  final int port;
  const Peer({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
  });
}

class TransferRecord {
  final String id, name, direction;
  String status = 'transferring';
  final int total;
  int transferred = 0;
  String? savedPath, error;
  bool get isComplete => status == 'complete';
  TransferRecord({
    required this.id,
    required this.name,
    required this.direction,
    required this.total,
  });
}

/// Direct trusted-LAN transport. HTTP and UDP are NOT encrypted; an on-path
/// attacker can read files/capabilities or impersonate peers. Approval is not
/// cryptographic identity verification. Never expose this service to the Internet.
class LanService {
  static const discoveryPort = 45873;
  static const maxFileBytes = 1024 * 1024 * 1024 * 1024;
  static const _timeout = Duration(seconds: 30);
  final String name, bindHost;
  final Directory receiveDirectory;
  final Future<bool> Function(Peer)? onConnectionRequest;
  final String deviceId = _random();
  final _events = StreamController<void>.broadcast();
  final Map<String, Peer> _peers = {};
  final Map<String, DateTime> _seen = {};
  final List<TransferRecord> _transfers = [];
  final Set<String> _reservedDestinations = {};
  final Set<StreamIterator<List<int>>> _readers = {};
  final Set<Completer<void>> _receives = {};
  HttpServer? _server;
  RawDatagramSocket? _udp;
  Timer? _timer;
  HttpClient? _client;
  Peer? _peer;
  String? _receiveToken, _sendToken;
  bool _connecting = false;
  int _generation = 0, _receiving = 0, _sending = 0, _handlers = 0;
  DateTime _lastProgress = DateTime.fromMillisecondsSinceEpoch(0);
  String _status = 'Stopped';

  LanService({
    required this.name,
    required this.receiveDirectory,
    this.onConnectionRequest,
    this.bindHost = '0.0.0.0',
  });
  List<Peer> get peers => List.unmodifiable(_peers.values);
  List<TransferRecord> get transfers => List.unmodifiable(_transfers);
  Peer? get connectedPeer => _peer;
  String get status => _status;
  int get port => _server?.port ?? 0;
  Stream<void> get changes => _events.stream;
  static String _random() =>
      base64Url.encode(List.generate(32, (_) => Random.secure().nextInt(256)));
  void _notify([String? message]) {
    if (message != null) _status = message;
    _events.add(null);
  }

  void _progress() {
    final now = DateTime.now();
    if (now.difference(_lastProgress).inMilliseconds >= 100) {
      _lastProgress = now;
      _notify();
    }
  }

  Map<String, Object> get _identity => {
    'id': deviceId,
    'name': name,
    'port': port,
  };
  HttpClient _newClient() => HttpClient()
    ..connectionTimeout = _timeout
    ..idleTimeout = _timeout
    ..findProxy = (_) => 'DIRECT';
  Future<void> start({bool discovery = true}) async {
    if (_server != null) return;
    await receiveDirectory.create(recursive: true);
    _server = await HttpServer.bind(bindHost, 0);
    _server!.idleTimeout = _timeout;
    _server!.listen(_handle);
    _notify('Ready');
    if (discovery) {
      try {
        _udp = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4,
          discoveryPort,
          reuseAddress: true,
        );
        _udp!.broadcastEnabled = true;
        _udp!.listen((event) {
          if (event != RawSocketEvent.read) return;
          Datagram? packet;
          while ((packet = _udp?.receive()) != null) {
            try {
              if (packet!.data.length > 4096) continue;
              final data = jsonDecode(utf8.decode(packet.data));
              if (data is! Map || data['protocol'] != 'neardrop-1') continue;
              if (data['type'] == 'discover') {
                if (data['id'] != deviceId) _announce(packet.address);
                continue;
              }
              if (data['type'] != null && data['type'] != 'announce') continue;
              final peer = _parsePeer(data, packet.address.address);
              if (peer.id == deviceId) continue;
              if (_peers.length >= 256 && !_peers.containsKey(peer.id))
                continue;
              _peers[peer.id] = peer;
              _seen[peer.id] = DateTime.now();
              _notify();
            } catch (_) {
              /* Ignore malformed unauthenticated advertisements. */
            }
          }
        });
        _announce();
        _timer = Timer.periodic(const Duration(seconds: 3), (_) {
          _announce();
          final expired = _seen.keys
              .where(
                (id) => DateTime.now().difference(_seen[id]!).inSeconds > 12,
              )
              .toList();
          for (final id in expired) {
            _seen.remove(id);
            _peers.remove(id);
          }
          if (expired.isNotEmpty) _notify();
        });
      } catch (_) {
        _notify('Ready; discovery unavailable. Use manual host and port.');
      }
    }
  }

  void _announce([InternetAddress? destination]) {
    try {
      _udp?.send(
        utf8.encode(
          jsonEncode({
            'protocol': 'neardrop-1',
            'type': 'announce',
            ..._identity,
          }),
        ),
        destination ?? InternetAddress('255.255.255.255'),
        discoveryPort,
      );
    } catch (_) {}
  }

  /// Immediately asks other NearDrop instances on the LAN to announce
  /// themselves. The regular three-second heartbeat remains in place.
  Future<void> refreshPeers() async {
    if (_server == null) throw StateError('Start the service first');
    final socket = _udp;
    if (socket == null) {
      _notify('Ready; discovery unavailable. Use manual host and port.');
      return;
    }
    final now = DateTime.now();
    final expired = _seen.keys
        .where((id) => now.difference(_seen[id]!).inSeconds > 12)
        .toList();
    for (final id in expired) {
      _seen.remove(id);
      _peers.remove(id);
    }
    _notify('Refreshing nearby devices');
    try {
      socket.send(
        utf8.encode(
          jsonEncode({
            'protocol': 'neardrop-1',
            'type': 'discover',
            'id': deviceId,
          }),
        ),
        InternetAddress('255.255.255.255'),
        discoveryPort,
      );
    } catch (_) {}
    _announce();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (_server != null) _notify('Ready');
  }

  Peer _parsePeer(Map data, String host) {
    final id = data['id'], peerName = data['name'], peerPort = data['port'];
    if (id is! String ||
        id.isEmpty ||
        id.length > 128 ||
        peerName is! String ||
        peerName.length > 256 ||
        peerPort is! int ||
        peerPort < 1 ||
        peerPort > 65535) {
      throw const FormatException('Invalid peer');
    }
    return Peer(id: id, name: peerName, host: host, port: peerPort);
  }

  Future<Map> _json(Stream<List<int>> stream) async {
    final bytes = <int>[];
    await for (final chunk in stream.timeout(_timeout)) {
      if (bytes.length + chunk.length > 16384)
        throw const FormatException('Body too large');
      bytes.addAll(chunk);
    }
    final data = jsonDecode(utf8.decode(bytes));
    if (data is! Map) throw const FormatException('Expected object');
    return data;
  }

  Future<void> _reply(HttpRequest request, int code, [Map? body]) async {
    request.response.statusCode = code;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(body ?? {}));
    await request.response.close().timeout(_timeout);
  }

  bool _authorized(HttpRequest request) =>
      _peer != null &&
      request.connectionInfo?.remoteAddress.address == _peer!.host &&
      request.headers.value('authorization') == 'Bearer $_receiveToken';
  Future<void> _handle(HttpRequest request) async {
    if (_handlers >= 12) {
      await _reply(request, 503);
      return;
    }
    _handlers++;
    try {
      final path = request.uri.path;
      if (path == '/identity' && request.method == 'GET') {
        await _reply(request, 200, _identity);
        return;
      }
      if (path == '/connect' && request.method == 'POST') {
        if (_peer != null || _connecting) {
          await _reply(request, 409);
          return;
        }
        _connecting = true;
        final generation = _generation;
        try {
          final data = await _json(request);
          final peer = _parsePeer(
            data,
            request.connectionInfo!.remoteAddress.address,
          );
          final token = data['token'];
          if (peer.id == deviceId ||
              token is! String ||
              !RegExp(r'^[A-Za-z0-9_-]{43}=$').hasMatch(token)) {
            await _reply(request, 400);
            return;
          }
          _notify('Connection request from ${peer.name}');
          final allowed =
              await (onConnectionRequest?.call(peer) ?? Future.value(false))
                  .timeout(_timeout, onTimeout: () => false);
          if (!allowed || generation != _generation || _server == null) {
            await _reply(request, 403);
            return;
          }
          _peer = peer;
          _sendToken = token;
          _receiveToken = _random();
          _client = _newClient();
          await _reply(request, 200, {..._identity, 'token': _receiveToken!});
          _notify('Connected to ${peer.name}');
        } catch (_) {
          if (generation == _generation && _peer != null) await _revoke();
          rethrow;
        } finally {
          _connecting = false;
        }
        return;
      }
      if (!_authorized(request)) {
        await _reply(request, 401);
        return;
      }
      if (path == '/disconnect' && request.method == 'POST') {
        await _revoke();
        await _reply(request, 200);
        return;
      }
      if (path == '/upload' && request.method == 'POST') {
        await _receive(request);
        return;
      }
      await _reply(request, 404);
    } catch (error) {
      _notify('Request failed: $error');
      try {
        await _reply(request, 400);
      } catch (_) {}
    } finally {
      _handlers--;
    }
  }

  Future<Peer> discoverHost(String host, int port) async {
    final client = _newClient();
    try {
      final request = await client
          .getUrl(
            Uri(scheme: 'http', host: host, port: port, path: '/identity'),
          )
          .timeout(_timeout);
      request.followRedirects = false;
      final response = await request.close().timeout(_timeout);
      if (response.statusCode != 200) throw HttpException('Discovery rejected');
      final remote = response.connectionInfo!.remoteAddress.address;
      return _parsePeer(await _json(response), remote);
    } finally {
      client.close(force: true);
    }
  }

  Future<void> connect(Peer peer) async {
    if (_server == null) throw StateError('Start the service first');
    if (_peer != null || _connecting)
      throw StateError('Already connected or connecting');
    _connecting = true;
    final generation = _generation;
    final client = _newClient();
    final token = _random();
    try {
      _notify('Connecting to ${peer.name}');
      final request = await client
          .postUrl(
            Uri(
              scheme: 'http',
              host: peer.host,
              port: peer.port,
              path: '/connect',
            ),
          )
          .timeout(_timeout);
      request.followRedirects = false;
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({..._identity, 'token': token}));
      final response = await request.close().timeout(_timeout);
      if (response.statusCode != 200)
        throw HttpException(
          'Connection declined or busy (${response.statusCode})',
        );
      final remote = response.connectionInfo!.remoteAddress.address;
      final data = await _json(response);
      final result = _parsePeer(data, remote);
      if (result.id != peer.id ||
          data['token'] is! String ||
          !RegExp(r'^[A-Za-z0-9_-]{43}=$').hasMatch(data['token']))
        throw const FormatException('Invalid handshake');
      if (generation != _generation) throw StateError('Connection cancelled');
      _peer = result;
      _receiveToken = token;
      _sendToken = data['token'];
      _client = client;
      _notify('Connected to ${result.name}');
    } catch (error) {
      client.close(force: true);
      _notify('Connection failed: $error');
      rethrow;
    } finally {
      _connecting = false;
    }
  }

  static String _safeName(String input) {
    var result = input
        .replaceAll('\\', '/')
        .split('/')
        .last
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_')
        .replaceAll(RegExp(r'[. ]+$'), '');
    if (result.isEmpty ||
        RegExp(
          r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)',
          caseSensitive: false,
        ).hasMatch(result))
      result = 'received_$result';
    if (result.length > 160) result = result.substring(0, 160);
    return result;
  }

  Future<File> _reserveDestination(String name) async {
    final separator = Platform.pathSeparator;
    final extensionIndex = name.lastIndexOf('.');
    final hasExtension = extensionIndex > 0 && extensionIndex < name.length - 1;
    final stem = hasExtension ? name.substring(0, extensionIndex) : name;
    final extension = hasExtension ? name.substring(extensionIndex) : '';
    for (var suffix = 0; suffix < 10000; suffix++) {
      final candidate = suffix == 0 ? name : '$stem ($suffix)$extension';
      final path = '${receiveDirectory.path}$separator$candidate';
      if (_reservedDestinations.contains(path) || await File(path).exists())
        continue;
      _reservedDestinations.add(path);
      return File(path);
    }
    throw StateError('Too many files named $name in the receiving folder');
  }

  Future<void> _receive(HttpRequest request) async {
    if (_receiving >= 2) {
      await _reply(request, 429);
      return;
    }
    final size = request.headers.contentLength;
    final originalName = request.uri.queryParameters['name'];
    if (size < 0 ||
        size > maxFileBytes ||
        originalName == null ||
        originalName.length > 1024) {
      await _reply(request, 400);
      return;
    }
    _receiving++;
    final finished = Completer<void>();
    _receives.add(finished);
    final generation = _generation;
    final record = TransferRecord(
      id: _random(),
      name: _safeName(originalName),
      direction: 'receive',
      total: size,
    );
    _transfers.add(record);
    _notify();
    File? destination;
    File? partial;
    File? saved;
    RandomAccessFile? output;
    StreamIterator<List<int>>? reader;
    try {
      // Keep completed files directly in NearDrop. A hidden, random partial
      // file is used in the same folder while streaming, then renamed only
      // after the exact byte count has been verified.
      destination = await _reserveDestination(record.name);
      partial = File(
        '${receiveDirectory.path}${Platform.pathSeparator}.neardrop_${_random()}.partial',
      );
      output = await partial.open(mode: FileMode.write);
      if (generation != _generation) throw StateError('Disconnected');
      reader = StreamIterator(request.timeout(_timeout));
      _readers.add(reader);
      while (await reader.moveNext()) {
        if (generation != _generation) throw StateError('Disconnected');
        if (record.transferred + reader.current.length > size)
          throw const FormatException('Size exceeded');
        await output.writeFrom(reader.current);
        record.transferred += reader.current.length;
        _progress();
      }
      await output.close();
      output = null;
      if (generation != _generation || record.transferred != size)
        throw const FormatException('Incomplete transfer');
      saved = await partial.rename(destination.path);
      if (generation != _generation) throw StateError('Disconnected');
      record.savedPath = saved.path;
      record.status = 'complete';
      await _reply(request, 200, {'size': size});
    } catch (error) {
      record.status = 'failed';
      record.error = '$error';
      if (output != null) {
        await output.close();
        output = null;
      }
      if (partial != null && await partial.exists()) await partial.delete();
      if (saved != null && await saved.exists()) await saved.delete();
      record.savedPath = null;
      rethrow;
    } finally {
      if (destination != null) _reservedDestinations.remove(destination.path);
      if (reader != null) {
        _readers.remove(reader);
        await reader.cancel();
      }
      _receiving--;
      _receives.remove(finished);
      finished.complete();
      _notify();
    }
  }

  Future<void> sendFile(File file) async {
    final peer = _peer, client = _client;
    if (peer == null || client == null) throw StateError('Not connected');
    if (_sending >= 2) throw StateError('Two sends already active');
    _sending++;
    final generation = _generation;
    TransferRecord? record;
    HttpClientRequest? outgoing;
    try {
      final size = await file.length();
      if (size > maxFileBytes) throw StateError('File too large');
      final filename = _safeName(file.uri.pathSegments.last);
      record = TransferRecord(
        id: _random(),
        name: filename,
        direction: 'send',
        total: size,
      );
      _transfers.add(record);
      _notify();
      final request = await client
          .postUrl(
            Uri(
              scheme: 'http',
              host: peer.host,
              port: peer.port,
              path: '/upload',
              queryParameters: {'name': filename},
            ),
          )
          .timeout(_timeout);
      outgoing = request;
      request.followRedirects = false;
      request.headers.set('authorization', 'Bearer $_sendToken');
      request.contentLength = size;
      await for (final chunk in file.openRead().timeout(_timeout)) {
        if (generation != _generation) throw StateError('Disconnected');
        request.add(chunk);
        await request.flush().timeout(_timeout);
        record.transferred += chunk.length;
        _progress();
      }
      final response = await request.close().timeout(_timeout);
      if (response.statusCode != 200)
        throw HttpException('Transfer rejected (${response.statusCode})');
      final result = await _json(response);
      if (result['size'] != size ||
          record.transferred != size ||
          generation != _generation)
        throw StateError('Incomplete transfer');
      record.status = 'complete';
    } catch (error) {
      outgoing?.abort(error);
      if (record != null) {
        record.status = 'failed';
        record.error = '$error';
      }
      _notify('Send failed: $error');
      rethrow;
    } finally {
      _sending--;
      _notify();
    }
  }

  Future<void> _revoke() async {
    _generation++;
    _peer = null;
    _receiveToken = null;
    _sendToken = null;
    _client?.close(force: true);
    _client = null;
    final receiving = _receives.map((c) => c.future).toList();
    for (final reader in _readers.toList()) {
      unawaited(reader.cancel());
    }
    _notify('Disconnected');
    await Future.wait(receiving);
  }

  Future<void> disconnect() async {
    final peer = _peer, token = _sendToken;
    await _revoke();
    if (peer == null) return;
    final client = _newClient();
    try {
      final request = await client
          .postUrl(
            Uri(
              scheme: 'http',
              host: peer.host,
              port: peer.port,
              path: '/disconnect',
            ),
          )
          .timeout(_timeout);
      request.headers.set('authorization', 'Bearer $token');
      request.followRedirects = false;
      final response = await request.close().timeout(_timeout);
      await response.drain<void>().timeout(_timeout);
    } catch (_) {
      /* Local capabilities are revoked even if peer is offline. */
    } finally {
      client.close(force: true);
    }
  }

  Future<void> stop() async {
    await disconnect();
    _timer?.cancel();
    _timer = null;
    _udp?.close();
    _udp = null;
    final server = _server;
    _server = null;
    await server?.close(force: true);
    _peers.clear();
    _seen.clear();
    _notify('Stopped');
  }
}
