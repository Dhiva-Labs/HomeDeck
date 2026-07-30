import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../connectors/connector.dart';
import '../connectors/ha/ha_client.dart';
import '../connectors/ha/ha_connector.dart';
import '../services/device_registry.dart';
import '../services/settings_store.dart';

class HaSettingsScreen extends StatefulWidget {
  const HaSettingsScreen({super.key});

  @override
  State<HaSettingsScreen> createState() => _HaSettingsScreenState();
}

class _HaSettingsScreenState extends State<HaSettingsScreen> {
  late final TextEditingController _url;
  late final TextEditingController _token;

  bool _busy = false;
  String? _message;
  bool _ok = false;

  @override
  void initState() {
    super.initState();
    final settings = context.read<SettingsStore>();
    _url = TextEditingController(text: settings.haUrl ?? '');
    _token = TextEditingController(text: settings.haToken ?? '');
  }

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _autodetect() async {
    setState(() {
      _busy = true;
      _message = 'Looking for Home Assistant on the network…';
      _ok = false;
    });
    final found = await HaConnector.discover();
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (found != null) {
        _url.text = found;
        _message = 'Found Home Assistant at $found';
        _ok = true;
      } else {
        _message = 'No instance answered. Type the address manually — it is '
            'usually http://homeassistant.local:8123';
      }
    });
  }

  Future<void> _test() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    final client =
        HaClient(baseUrl: _url.text.trim(), token: _token.text.trim());
    final result = await client.testConnection();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = result.message;
      _ok = result.ok;
    });
  }

  Future<void> _save() async {
    final settings = context.read<SettingsStore>();
    final connector = context.read<HaConnector>();
    settings.haUrl = _url.text.trim();
    settings.haToken = _token.text.trim();
    await connector.configure(
      baseUrl: settings.haUrl,
      token: settings.haToken,
    );
    if (mounted) Navigator.pop(context);
  }

  Future<void> _disconnect() async {
    final settings = context.read<SettingsStore>();
    final connector = context.read<HaConnector>();
    final registry = context.read<DeviceRegistry>();
    settings.haUrl = null;
    settings.haToken = null;
    await connector.configure(baseUrl: null, token: null);
    for (final device in registry.byConnector('ha')) {
      registry.forget(device.id);
    }
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final connector = context.watch<HaConnector>();
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Home Assistant')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(
                    switch (connector.status) {
                      ConnectorStatus.connected => Icons.check_circle,
                      ConnectorStatus.error => Icons.error_outline,
                      ConnectorStatus.starting => Icons.sync,
                      ConnectorStatus.disabled => Icons.cloud_off,
                    },
                    color: switch (connector.status) {
                      ConnectorStatus.connected => Colors.green,
                      ConnectorStatus.error => scheme.error,
                      _ => scheme.outline,
                    },
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(connector.statusMessage ??
                        connector.status.name),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _url,
            decoration: InputDecoration(
              labelText: 'Address',
              hintText: 'http://homeassistant.local:8123',
              suffixIcon: IconButton(
                icon: const Icon(Icons.search),
                tooltip: 'Find on network',
                onPressed: _busy ? null : _autodetect,
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _token,
            obscureText: true,
            maxLines: 1,
            decoration: const InputDecoration(
              labelText: 'Long-lived access token',
              helperText: 'Home Assistant → your profile → Security → '
                  'Long-lived access tokens → Create token',
              helperMaxLines: 3,
            ),
          ),
          if (_message != null) ...[
            const SizedBox(height: 16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  _ok ? Icons.check_circle_outline : Icons.info_outline,
                  size: 18,
                  color: _ok ? Colors.green : scheme.outline,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(_message!,
                      style: Theme.of(context).textTheme.bodySmall),
                ),
              ],
            ),
          ],
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _busy ? null : _test,
                  child: _busy
                      ? const SizedBox(
                          height: 16,
                          width: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Test'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _busy ? null : _save,
                  child: const Text('Save & connect'),
                ),
              ),
            ],
          ),
          if (connector.configured) ...[
            const SizedBox(height: 8),
            TextButton(
              onPressed: _disconnect,
              child: const Text('Disconnect'),
            ),
          ],
        ],
      ),
    );
  }
}
