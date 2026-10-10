import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../lib/network/lan_service.dart';

void main() {
  late Directory root;
  late LanService a, b;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('neardrop_test_');
    a = LanService(
      name: 'A',
      receiveDirectory: Directory('${root.path}/a'),
      bindHost: '127.0.0.1',
      onConnectionRequest: (_) async => true,
    );
    b = LanService(
      name: 'B',
      receiveDirectory: Directory('${root.path}/b'),
      bindHost: '127.0.0.1',
      onConnectionRequest: (_) async => true,
    );
    await a.start(discovery: false);
    await b.start(discovery: false);
  });
  tearDown(() async {
    await a.stop();
    await b.stop();
    if (await root.exists()) await root.delete(recursive: true);
  });
  Future<void> connect() async =>
      a.connect(await a.discoverHost('127.0.0.1', b.port));

  test('approval decline leaves both sides disconnected', () async {
    await b.stop();
    b = LanService(
      name: 'Decline',
      receiveDirectory: Directory('${root.path}/b'),
      bindHost: '127.0.0.1',
      onConnectionRequest: (_) async => false,
    );
    await b.start(discovery: false);
    await expectLater(connect(), throwsA(isA<HttpException>()));
    expect(a.connectedPeer, isNull);
    expect(b.connectedPeer, isNull);
  });

  test('upload requires a capability even from connected host', () async {
    await connect();
    final client = HttpClient();
    try {
      final request = await client.postUrl(
        Uri.parse('http://127.0.0.1:${b.port}/upload?name=bad.txt'),
      );
      request.contentLength = 3;
      request.add([1, 2, 3]);
      final response = await request.close();
      expect(response.statusCode, 401);
      await response.drain<void>();
      expect(b.transfers, isEmpty);
    } finally {
      client.close(force: true);
    }
  });

  test(
    'mutual connection and simultaneous streamed files match exactly',
    () async {
      await connect();
      expect(a.connectedPeer!.id, b.deviceId);
      expect(b.connectedPeer!.id, a.deviceId);
      final left = List<int>.generate(1024 * 1024 + 17, (i) => i % 251);
      final right = List<int>.generate(768 * 1024 + 9, (i) => 255 - i % 251);
      final fa = await File('${root.path}/left.bin').writeAsBytes(left);
      final fb = await File('${root.path}/right.bin').writeAsBytes(right);
      await Future.wait([a.sendFile(fa), b.sendFile(fb)]);
      final ar = a.transfers.singleWhere((t) => t.direction == 'receive');
      final br = b.transfers.singleWhere((t) => t.direction == 'receive');
      expect(ar.isComplete, isTrue);
      expect(br.isComplete, isTrue);
      expect(await File(ar.savedPath!).readAsBytes(), right);
      expect(await File(br.savedPath!).readAsBytes(), left);
      await a.sendFile(fa);
      final received = b.transfers
          .where((t) => t.direction == 'receive')
          .toList();
      expect(received[0].savedPath, isNot(received[1].savedPath));
      await a.disconnect();
      expect(a.connectedPeer, isNull);
      expect(b.connectedPeer, isNull);
      await expectLater(a.sendFile(fa), throwsStateError);
    },
  );

  test('approved raw peer traversal is contained and token revoked', () async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(
        Uri.parse('http://127.0.0.1:${b.port}/connect'),
      );
      request.write(
        jsonEncode({
          'id': 'raw',
          'name': 'Raw',
          'host': 'evil.invalid',
          'port': a.port,
          'token': base64Url.encode(List.filled(32, 42)),
        }),
      );
      final response = await request.close();
      expect(response.statusCode, 200);
      final data = jsonDecode(await utf8.decoder.bind(response).join()) as Map;
      expect(b.connectedPeer!.host, '127.0.0.1');
      Future<int> upload() async {
        final r = await client.postUrl(
          Uri(
            scheme: 'http',
            host: '127.0.0.1',
            port: b.port,
            path: '/upload',
            queryParameters: {'name': '../../outside.txt'},
          ),
        );
        r.headers.set('authorization', 'Bearer ${data['token']}');
        r.contentLength = 4;
        r.add([4, 3, 2, 1]);
        final result = await r.close();
        final code = result.statusCode;
        await result.drain<void>();
        return code;
      }

      expect(await upload(), 200);
      final saved = b.transfers.single.savedPath!;
      expect(
        saved.startsWith('${b.receiveDirectory.path}${Platform.pathSeparator}'),
        isTrue,
      );
      expect(File(saved).parent.path, b.receiveDirectory.path);
      expect(await File(saved).readAsBytes(), [4, 3, 2, 1]);
      expect(await File('${root.path}/outside.txt').exists(), isFalse);
      await b.disconnect();
      expect(await upload(), 401);
    } finally {
      client.close(force: true);
    }
  });

  test(
    'cross connection requests fail cleanly without implicit approval',
    () async {
      final pa = await b.discoverHost('127.0.0.1', a.port);
      final pb = await a.discoverHost('127.0.0.1', b.port);
      final results = await Future.wait([
        a.connect(pb).then((_) => true, onError: (_) => false),
        b.connect(pa).then((_) => true, onError: (_) => false),
      ]);
      expect(results, [false, false]);
      expect(a.connectedPeer, isNull);
      expect(b.connectedPeer, isNull);
    },
  );
}
