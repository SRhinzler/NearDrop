import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/main.dart';
import '../lib/network/lan_service.dart';
import '../lib/ui/panels.dart';

void main() {
  testWidgets('offline screen disables sending without opening networking', (tester) async {
    await tester.pumpWidget(const NearDropApp(autoStart: false));
    expect(find.text('NearDrop'), findsOneWidget);
    expect(find.text('Discovery is offline'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Send files'), 200);
    final button = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Send files'));
    expect(button.onPressed, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('trust notice makes transport privacy clear', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: TransferSafetyNotice())));
    expect(find.textContaining('not end-to-end encrypted'), findsOneWidget);
    expect(find.textContaining('trusted LANs only'), findsOneWidget);
  });

  testWidgets('completed received files expose a save and share action', (tester) async {
    final record = TransferRecord(
      id: 'received-1',
      name: 'photo.jpg',
      direction: 'receive',
      total: 10,
    )
      ..transferred = 10
      ..status = 'complete'
      ..savedPath = r'C:\NearDrop\photo.jpg';
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TransferTile(record: record, onShare: () {}),
      ),
    ));
    expect(find.text('Save / share'), findsOneWidget);
    expect(find.textContaining(r'C:\NearDrop\photo.jpg'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('startup failures leave a retry action and useful error', (tester) async {
    await tester.pumpWidget(NearDropApp(serviceFactory: (_) async => throw StateError('Port is busy')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Port is busy'), findsOneWidget);
    expect(find.text('Start discovery'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('manual connection rejects empty hosts and invalid ports', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: AddressDialog(defaultPort: 45873))));
    await tester.enterText(find.byType(TextFormField).last, '70000');
    await tester.tap(find.text('Connect'));
    await tester.pump();
    expect(find.text('Enter an address'), findsOneWidget);
    expect(find.text('Use a port from 1 to 65535'), findsOneWidget);
  });

  testWidgets('phone layout remains usable without horizontal overflow', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const NearDropApp(autoStart: false));
    await tester.scrollUntilVisible(find.text('Receiving folder'), 250);
    expect(find.text('Receiving folder'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
