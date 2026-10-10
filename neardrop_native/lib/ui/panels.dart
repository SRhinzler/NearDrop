import 'package:flutter/material.dart';

import '../network/lan_service.dart';

class BrandHeader extends StatelessWidget {
  const BrandHeader({super.key});

  @override
  Widget build(BuildContext context) => Row(children: [
    Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(color: Theme.of(context).colorScheme.primary, borderRadius: BorderRadius.circular(18)),
      child: const Icon(Icons.near_me_rounded, color: Colors.white, size: 29),
    ),
    const SizedBox(width: 14),
    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('NearDrop', style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -1)),
      const Text('Your files. Just a little closer.'),
    ])),
  ]);
}

class SectionPanel extends StatelessWidget {
  const SectionPanel({super.key, required this.title, this.subtitle, this.trailing, required this.children});
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Card(
    color: Theme.of(context).colorScheme.surface,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.55))),
    child: Padding(
      padding: const EdgeInsets.all(22),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(title, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700))),
          if (trailing != null) ...[const SizedBox(width: 12), trailing!],
        ]),
        if (subtitle != null) ...[
          const SizedBox(height: 6),
          Text(subtitle!, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ],
        const SizedBox(height: 20),
        ...children,
      ]),
    ),
  );
}

class EmptyPanel extends StatelessWidget {
  const EmptyPanel({super.key, required this.icon, required this.title, required this.text});
  final IconData icon;
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 20),
    child: Center(child: Column(children: [
      Icon(icon, size: 36, color: Theme.of(context).colorScheme.outline),
      const SizedBox(height: 14),
      Text(title, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      ConstrainedBox(constraints: const BoxConstraints(maxWidth: 380), child: Text(text, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall)),
    ])),
  );
}

class DeviceTile extends StatelessWidget {
  const DeviceTile({super.key, required this.name, required this.address, required this.connected, this.onConnect});
  final String name;
  final String address;
  final bool connected;
  final VoidCallback? onConnect;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerLow, borderRadius: BorderRadius.circular(16)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Icon(Icons.devices_rounded),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(name, style: const TextStyle(fontWeight: FontWeight.w700)),
          Text(address, style: Theme.of(context).textTheme.bodySmall),
        ])),
      ]),
      const SizedBox(height: 10),
      Align(alignment: Alignment.centerRight, child: OutlinedButton(onPressed: connected ? null : onConnect, child: Text(connected ? 'Connected' : 'Connect'))),
    ]),
  );
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

class TransferTile extends StatelessWidget {
  const TransferTile({super.key, required this.record, this.onShare});
  final TransferRecord record;
  final VoidCallback? onShare;

  @override
  Widget build(BuildContext context) {
    final incoming = record.direction.toLowerCase().startsWith('in') || record.direction.toLowerCase().startsWith('receiv');
    final progress = record.isComplete ? 1.0 : record.total > 0 ? (record.transferred / record.total).clamp(0.0, 1.0).toDouble() : 0.0;
    final failed = record.error != null || record.status.toLowerCase().contains('fail');
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          CircleAvatar(
            backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Icon(incoming ? Icons.south_west_rounded : Icons.north_east_rounded),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(record.name, style: const TextStyle(fontWeight: FontWeight.w700)),
            Text('${incoming ? 'Receiving' : 'Sending'} · ${record.status}', style: Theme.of(context).textTheme.bodySmall),
          ])),
          if (record.isComplete) const Icon(Icons.check_circle, color: Color(0xff238557)),
          if (failed) Icon(Icons.error_outline, color: Theme.of(context).colorScheme.error),
        ]),
        const SizedBox(height: 12),
        LinearProgressIndicator(value: progress, minHeight: 6, borderRadius: BorderRadius.circular(6), color: failed ? Theme.of(context).colorScheme.error : null),
        const SizedBox(height: 7),
        Text('${formatBytes(record.transferred)} / ${formatBytes(record.total)} · ${(progress * 100).round()}%', style: Theme.of(context).textTheme.bodySmall),
        if (record.error != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(record.error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
        if (record.isComplete && record.savedPath != null) ...[
          const SizedBox(height: 6),
          SelectableText('Saved to ${record.savedPath}', style: Theme.of(context).textTheme.bodySmall),
        ],
         if (onShare != null) TextButton.icon(onPressed: onShare, icon: const Icon(Icons.ios_share), label: const Text('Save / share')),
      ]),
    );
  }
}

class TransferSafetyNotice extends StatelessWidget {
  const TransferSafetyNotice({super.key});

  @override
  Widget build(BuildContext context) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Icon(Icons.info_outline, size: 19, color: Theme.of(context).colorScheme.onSurfaceVariant),
    const SizedBox(width: 10),
    Expanded(child: Text('For trusted LANs only. Transfers use plain local-network connections and are not end-to-end encrypted. Only connect to devices you recognize.', style: Theme.of(context).textTheme.bodySmall)),
  ]);
}

class AddressDialog extends StatefulWidget {
  const AddressDialog({super.key, required this.defaultPort});
  final int defaultPort;

  @override
  State<AddressDialog> createState() => _AddressDialogState();
}

class _AddressDialogState extends State<AddressDialog> {
  final _address = TextEditingController();
  late final _port = TextEditingController(text: '${widget.defaultPort}');
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _address.dispose();
    _port.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Connect by address'),
    content: SingleChildScrollView(child: Form(
      key: _formKey,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('Enter the other device’s local IP address and NearDrop listening port. Only connect to a device you trust.'),
        const SizedBox(height: 20),
        TextFormField(
          controller: _address,
          decoration: const InputDecoration(labelText: 'Host or IP address', hintText: '192.168.1.10'),
          autocorrect: false,
          validator: (value) => value == null || value.trim().isEmpty ? 'Enter an address' : null,
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: _port,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Port'),
          validator: (value) {
            final number = int.tryParse(value ?? '');
            return number == null || number < 1 || number > 65535 ? 'Use a port from 1 to 65535' : null;
          },
        ),
      ]),
    )),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(
        onPressed: () {
          if (_formKey.currentState!.validate()) {
            Navigator.pop(context, (_address.text.trim(), int.parse(_port.text)));
          }
        },
        child: const Text('Connect'),
      ),
    ],
  );
}
