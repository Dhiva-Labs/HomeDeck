import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../connectors/connector.dart';
import '../connectors/hue/hue_connector.dart';
import '../services/settings_store.dart';

class HueSettingsScreen extends StatefulWidget {
  const HueSettingsScreen({super.key});

  @override
  State<HueSettingsScreen> createState() => _HueSettingsScreenState();
}

class _HueSettingsScreenState extends State<HueSettingsScreen> {
  late final TextEditingController _ip;
  bool _busy = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _ip = TextEditingController(
        text: context.read<SettingsStore>().hueBridgeIp ?? '');
  }

  @override
  void dispose() {
    _ip.dispose();
    super.dispose();
  }

  Future<void> _discover() async {
    setState(() {
      _busy = true;
      _message = 'Searching for bridges…';
    });
    final bridges = await HueConnector.discoverBridges();
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (bridges.isEmpty) {
        _message = 'No bridge found. Enter its IP manually.';
      } else {
        _ip.text = bridges.first;
        _message = 'Found bridge at ${bridges.first}.';
      }
    });
  }

  /// The link-button dance: the user presses the physical button on the
  /// bridge, then taps Pair within 30 seconds.
  Future<void> _pair() async {
    final ip = _ip.text.trim();
    if (ip.isEmpty) return;
    final connector = context.read<HueConnector>();
    final settings = context.read<SettingsStore>();
    setState(() {
      _busy = true;
      _message = 'Pairing…';
    });
    final result = await connector.pairWithBridge(ip);
    if (!mounted) return;
    if (result.ok) {
      settings.hueBridgeIp = ip;
      settings.hueAppKey = result.applicationKey;
      await connector.configure(
        bridgeIp: ip,
        applicationKey: result.applicationKey,
      );
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = result.message;
    });
  }

  @override
  Widget build(BuildContext context) {
    final connector = context.watch<HueConnector>();

    return Scaffold(
      appBar: AppBar(title: const Text('Philips Hue')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Connects directly to the Hue Bridge on your network — no cloud '
            'account. Press the round link button on the bridge, then pair '
            'within 30 seconds.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _ip,
            decoration: const InputDecoration(
              labelText: 'Bridge IP',
              hintText: '192.168.1.x',
            ),
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: _busy ? null : _discover,
                icon: const Icon(Icons.search),
                label: const Text('Find bridge'),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                onPressed: _busy ? null : _pair,
                icon: const Icon(Icons.link),
                label: const Text('Pair'),
              ),
            ],
          ),
          if (_message != null) ...[
            const SizedBox(height: 16),
            Text(_message!),
          ],
          const SizedBox(height: 16),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              connector.status == ConnectorStatus.connected
                  ? Icons.check_circle
                  : Icons.circle_outlined,
              color: connector.status == ConnectorStatus.connected
                  ? Colors.green
                  : null,
            ),
            title: Text('Status: ${connector.status.name}'),
            subtitle: connector.statusMessage == null
                ? null
                : Text(connector.statusMessage!),
          ),
        ],
      ),
    );
  }
}
