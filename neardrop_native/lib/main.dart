import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'network/lan_service.dart';
import 'platform_bridge.dart';
import 'ui/panels.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const NearDropApp());
}

/// A factory returns an already-started service. Tests may disable autoStart to
/// exercise the complete empty screen without opening sockets or platform APIs.
typedef ServiceFactory = Future<LanService> Function(
  Future<bool> Function(Peer peer) approve,
);

class NearDropApp extends StatelessWidget {
  const NearDropApp({super.key, this.serviceFactory, this.autoStart = true});

  final ServiceFactory? serviceFactory;
  final bool autoStart;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NearDrop',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff4263eb),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xfff5f7fc),
        cardTheme: const CardThemeData(elevation: 0, margin: EdgeInsets.zero),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
          filled: true,
        ),
      ),
      home: NearDropHome(serviceFactory: serviceFactory, autoStart: autoStart),
    );
  }
}

class NearDropHome extends StatefulWidget {
  const NearDropHome({super.key, this.serviceFactory, this.autoStart = true});

  final ServiceFactory? serviceFactory;
  final bool autoStart;

  @override
  State<NearDropHome> createState() => _NearDropHomeState();
}

class _NearDropHomeState extends State<NearDropHome> {
  LanService? _service;
  StreamSubscription<void>? _subscription;
  bool _starting = false;
  bool _connecting = false;
  bool _picking = false;
  bool _refreshing = false;
  bool _approvalOpen = false;
  bool _multicastAcquired = false;
  String? _error;
  String? _folder;
  String _deviceName = 'This device';

  @override
  void initState() {
    super.initState();
    if (widget.autoStart) unawaited(_start());
  }

  Future<LanService> _createService() async {
    _deviceName = Platform.localHostname.trim();
    if (_deviceName.isEmpty) {
      _deviceName = Platform.isAndroid ? 'Android device' : 'Windows PC';
    }
    late final Directory directory;
    if (Platform.isAndroid) {
      final publicPath = await DiscoveryPlatform.publicReceiveDirectory();
      if (publicPath == null || publicPath.isEmpty) {
        throw StateError('Android public storage is unavailable.');
      }
      // The platform method already returns /storage/emulated/0/NearDrop.
      directory = Directory(publicPath);
    } else if (Platform.isWindows) {
      Directory? base;
      try {
        base = await getDownloadsDirectory();
      } catch (_) {
        // Downloads is optional; documents is the supported fallback.
      }
      base ??= await getApplicationDocumentsDirectory();
      directory = Directory('${base.path}${Platform.pathSeparator}NearDrop');
    } else {
      final base = await getApplicationDocumentsDirectory();
      directory = Directory('${base.path}${Platform.pathSeparator}NearDrop');
    }
    await directory.create(recursive: true);
    _folder = directory.path;
    try {
      await DiscoveryPlatform.acquire();
      _multicastAcquired = Platform.isAndroid;
    } catch (error) {
      _error =
          'Automatic discovery may be unavailable: $error. '
          'You can still connect by address.';
    }
    final service = LanService(
      name: _deviceName,
      receiveDirectory: directory,
      onConnectionRequest: _approve,
    );
    try {
      await service.start();
      return service;
    } catch (_) {
      await _shutdown(service);
      rethrow;
    }
  }

  Future<void> _start() async {
    if (_starting || _service != null) return;
    setState(() {
      _starting = true;
      _error = null;
    });
    try {
      final service =
          await (widget.serviceFactory?.call(_approve) ?? _createService());
      if (!mounted) {
        await _shutdown(service);
        return;
      }
      _service = service;
      _subscription = service.changes.listen((_) {
        if (mounted) setState(() {});
      }, onError: (Object error) => _showError(error));
    } catch (error) {
      _showError('Could not start NearDrop: $error');
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _shutdown(LanService? service) async {
    try {
      await service?.stop();
    } catch (_) {
      // Cleanup must not produce an unhandled asynchronous error on disposal.
    } finally {
      if (_multicastAcquired) {
        _multicastAcquired = false;
        try {
          await DiscoveryPlatform.release();
        } catch (_) {}
      }
    }
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    unawaited(_shutdown(_service));
    super.dispose();
  }

  void _showError(Object error) {
    if (mounted) setState(() => _error = error.toString());
  }

  Future<bool> _approve(Peer peer) async {
    if (!mounted || _approvalOpen) return false;
    _approvalOpen = true;
    try {
      return await showDialog<bool>(
            context: context,
            barrierDismissible: false,
            builder: (context) => AlertDialog(
              icon: const Icon(Icons.devices_rounded),
              title: Text('Connect with ${peer.name}?'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${peer.host}:${peer.port}'),
                    const SizedBox(height: 16),
                    const Text(
                      'Allow this device to send files to your receiving folder '
                      'and receive files you choose to send until you disconnect.',
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Only allow a device you recognize. Names are self-reported. '
                      'Transfers use plain local-network connections and are not '
                      'end-to-end encrypted.',
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Decline'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Allow'),
                ),
              ],
            ),
          ) ??
          false;
    } finally {
      _approvalOpen = false;
    }
  }

  Future<void> _connect(Peer peer) async {
    if (_connecting || _service == null) return;
    setState(() => _connecting = true);
    try {
      await _service!.connect(peer);
    } catch (error) {
      _showError('Connection failed: $error');
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  Future<void> _manualConnect() async {
    final endpoint = await showDialog<(String, int)>(
      context: context,
      builder: (context) => AddressDialog(defaultPort: _service?.port ?? 45873),
    );
    if (endpoint == null || !mounted || _service == null || _connecting) return;
    setState(() => _connecting = true);
    try {
      final peer = await _service!.discoverHost(endpoint.$1, endpoint.$2);
      if (!mounted) return;
      await _service!.connect(peer);
    } catch (error) {
      _showError('Could not reach that device: $error');
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  Future<void> _pickFiles() async {
    if (_picking || _service?.connectedPeer == null) return;
    setState(() => _picking = true);
    try {
      final result = await FilePicker.pickFiles();
      if (!mounted) return;
      for (final selected in result) {
        if (selected.path == null) {
          _showError(
            'Could not access ${selected.name}. Choose a locally available file.',
          );
          continue;
        }
        // Every send streams independently in the network service.
        unawaited(_sendFile(File(selected.path!)));
      }
    } catch (error) {
      _showError('Could not choose files: $error');
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _sendFile(File file) async {
    try {
      await _service?.sendFile(file);
    } catch (error) {
      _showError('File transfer failed: $error');
    }
  }

  Future<void> _disconnect() async {
    try {
      await _service?.disconnect();
      if (mounted) setState(() {});
    } catch (error) {
      _showError('Could not disconnect: $error');
    }
  }

  Future<void> _refreshNearby() async {
    final service = _service;
    if (service == null || _refreshing) return;
    setState(() => _refreshing = true);
    try {
      await service.refreshPeers();
    } catch (error) {
      _showError('Could not refresh nearby devices: $error');
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _share(TransferRecord transfer) async {
    if (transfer.savedPath == null) return;
    try {
      await SharePlus.instance.share(
        ShareParams(files: [XFile(transfer.savedPath!)]),
      );
    } catch (error) {
      _showError('Could not export ${transfer.name}: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = _service;
    final connected = service?.connectedPeer;
    final transfers = service?.transfers ?? <TransferRecord>[];
    final peers = service?.peers ?? <Peer>[];
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1240),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                const BrandHeader(),
                const SizedBox(height: 28),
                Wrap(
                  spacing: 12,
                  runSpacing: 10,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Chip(
                      avatar: Icon(
                        Platform.isAndroid
                            ? Icons.phone_android
                            : Icons.computer,
                        size: 18,
                      ),
                      label: Text(_deviceName),
                    ),
                    Chip(
                      avatar: Icon(
                        service == null
                            ? Icons.radio_button_unchecked
                            : Icons.radar,
                        size: 18,
                      ),
                      label: Text(
                        _starting
                            ? 'Starting discovery…'
                            : service?.status ?? 'Discovery is offline',
                      ),
                    ),
                    if (service != null)
                      Text('Listening on port ${service.port}'),
                  ],
                ),
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Material(
                    color: Theme.of(context).colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(16),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                      child: Row(
                        children: [
                          const Icon(Icons.info_outline),
                          const SizedBox(width: 12),
                          Expanded(child: Text(_error!)),
                          IconButton(
                            onPressed: () => setState(() => _error = null),
                            tooltip: 'Dismiss error',
                            icon: const Icon(Icons.close),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                if (service == null) ...[
                  const SizedBox(height: 16),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton.icon(
                      onPressed: _starting ? null : _start,
                      icon: const Icon(Icons.refresh),
                      label: Text(_starting ? 'Starting…' : 'Start discovery'),
                    ),
                  ),
                ],
                const SizedBox(height: 22),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final nearby = SectionPanel(
                      title: 'Nearby devices',
                      subtitle: 'Open NearDrop on both devices using the same Wi-Fi or LAN.',
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            onPressed: service == null || _refreshing
                                ? null
                                : _refreshNearby,
                            tooltip: 'Refresh nearby devices',
                            icon: _refreshing
                                ? const SizedBox.square(
                                    dimension: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.refresh),
                          ),
                          const Icon(Icons.radar),
                        ],
                      ),
                      children: [
                        if (peers.isEmpty)
                          const EmptyPanel(
                            icon: Icons.devices_other_rounded,
                            title: 'Your next connection is nearby',
                            text: 'Devices appear here automatically. Keep both apps open and allow NearDrop through your firewall.',
                          )
                        else
                          for (final peer in peers)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: DeviceTile(
                                name: peer.name,
                                address: '${peer.host}:${peer.port}',
                                connected: connected?.id == peer.id,
                                onConnect: _connecting || connected != null
                                    ? null
                                    : () => _connect(peer),
                              ),
                            ),
                        const SizedBox(height: 8),
                        TextButton.icon(
                          onPressed:
                              service == null ||
                                  _connecting ||
                                  connected != null
                              ? null
                              : _manualConnect,
                          icon: const Icon(Icons.link),
                          label: Text(
                            _connecting
                                ? 'Waiting for connection…'
                                : 'Connect by address',
                          ),
                        ),
                      ],
                    );
                    final sending = SectionPanel(
                      title: connected == null
                          ? 'Ready when you are'
                          : 'Connected to ${connected.name}',
                      subtitle: connected == null
                          ? 'Connect with a nearby device to start sending.'
                          : '${connected.host}:${connected.port}',
                      trailing: Icon(
                        connected == null
                            ? Icons.swap_horiz_rounded
                            : Icons.check_circle_outline,
                      ),
                      children: [
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(24),
                          decoration: BoxDecoration(
                            color: Theme.of(context)
                                .colorScheme
                                .primaryContainer
                                .withValues(alpha: 0.35),
                            borderRadius: BorderRadius.circular(18),
                          ),
                          child: Column(
                            children: [
                              Icon(
                                Icons.file_upload_outlined,
                                size: 42,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                              const SizedBox(height: 12),
                              const Text(
                                'Big files. Short distance.',
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 18,
                                ),
                              ),
                              const SizedBox(height: 8),
                              const Text(
                                'Choose multiple files. Watch each transfer live.',
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 20),
                              FilledButton.icon(
                                onPressed: connected == null || _picking
                                    ? null
                                    : _pickFiles,
                                icon: const Icon(Icons.add),
                                label: Text(
                                  _picking ? 'Choosing files…' : 'Send files',
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (connected != null) ...[
                          const SizedBox(height: 8),
                          TextButton.icon(
                            onPressed: _disconnect,
                            icon: const Icon(Icons.link_off),
                            label: const Text('Disconnect'),
                          ),
                        ],
                      ],
                    );
                    if (constraints.maxWidth < 780) {
                      return Column(
                        children: [nearby, const SizedBox(height: 18), sending],
                      );
                    }
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: nearby),
                        const SizedBox(width: 20),
                        Expanded(child: sending),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 20),
                SectionPanel(
                  title: 'Transfers',
                  subtitle: 'Incoming and outgoing • this session',
                  trailing: Text(
                    '${transfers.length}',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  children: [
                    if (transfers.isEmpty)
                      const EmptyPanel(
                        icon: Icons.folder_copy_outlined,
                        title: 'A clear path for your files',
                        text: 'Transfer progress and completed files will appear here.',
                      )
                    else
                      for (final transfer in transfers.reversed)
                        TransferTile(
                          record: transfer,
                          // Received files are already persisted by LanService. Keep the
                          // export action available on both Windows and Android so the
                          // user can hand a completed file to the platform share sheet.
                          onShare:
                              transfer.isComplete && transfer.savedPath != null
                              ? () => _share(transfer)
                              : null,
                        ),
                  ],
                ),
                const SizedBox(height: 20),
                SectionPanel(
                  title: 'Receiving folder',
                  trailing: const Icon(Icons.folder_outlined),
                  children: [
                    SelectableText(
                      _folder ??
                          'Preparing a local folder when discovery starts…',
                    ),
                    const SizedBox(height: 8),
                    Text(
                      Platform.isAndroid
                          ? 'Received files are saved directly in the shared internal-storage root at /NearDrop. Android may ask you to allow NearDrop access to manage files. This lets other file managers see the received files.'
                          : 'Received files are saved in Downloads/NearDrop when available, otherwise in Documents/NearDrop. Completed file paths appear in your transfer history.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                const TransferSafetyNotice(),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
