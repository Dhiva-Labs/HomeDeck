import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../connectors/connector.dart';
import '../connectors/mqtt/mqtt_connector.dart';
import '../models/device.dart';
import '../services/device_registry.dart';
import '../services/settings_store.dart';

class MqttSettingsScreen extends StatefulWidget {
  const MqttSettingsScreen({super.key});

  @override
  State<MqttSettingsScreen> createState() => _MqttSettingsScreenState();
}

class _MqttSettingsScreenState extends State<MqttSettingsScreen> {
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _user;
  late final TextEditingController _pass;

  @override
  void initState() {
    super.initState();
    final settings = context.read<SettingsStore>();
    _host = TextEditingController(text: settings.mqttBroker ?? '');
    _port = TextEditingController(text: '${settings.mqttPort}');
    _user = TextEditingController(text: settings.mqttUsername ?? '');
    _pass = TextEditingController(text: settings.mqttPassword ?? '');
  }

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  /// Offer any host the network scan saw listening on 1883.
  List<Device> _candidates(BuildContext context) => context
      .watch<DeviceRegistry>()
      .devices
      .where((device) => device.attrs['mqttCandidate'] == true)
      .toList();

  Future<void> _save() async {
    final settings = context.read<SettingsStore>();
    final connector = context.read<MqttConnector>();
    settings.mqttBroker = _host.text.trim();
    settings.mqttPort = int.tryParse(_port.text.trim()) ?? 1883;
    settings.mqttUsername = _user.text.trim();
    settings.mqttPassword = _pass.text;
    await connector.configure(
      host: settings.mqttBroker,
      port: settings.mqttPort,
      username: settings.mqttUsername,
      password: settings.mqttPassword,
    );
    if (mounted) Navigator.pop(context);
  }

  Future<void> _disconnect() async {
    final settings = context.read<SettingsStore>();
    final connector = context.read<MqttConnector>();
    final registry = context.read<DeviceRegistry>();
    settings.mqttBroker = null;
    await connector.configure(host: null);
    for (final device in registry.byConnector('mqtt')) {
      registry.forget(device.id);
    }
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final connector = context.watch<MqttConnector>();
    final scheme = Theme.of(context).colorScheme;
    final candidates = _candidates(context);

    return Scaffold(
      appBar: AppBar(title: const Text('MQTT broker')),
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
                    child: Text(
                        connector.statusMessage ?? connector.status.name),
                  ),
                ],
              ),
            ),
          ),
          if (candidates.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('Found on your network',
                style: Theme.of(context).textTheme.labelLarge),
            for (final candidate in candidates)
              ListTile(
                leading: const Icon(Icons.hub_outlined),
                title: Text(candidate.name),
                subtitle: Text('${candidate.ip} — port 1883 open'),
                onTap: () => setState(() => _host.text = candidate.ip ?? ''),
              ),
          ],
          const SizedBox(height: 16),
          TextField(
            controller: _host,
            decoration: const InputDecoration(
              labelText: 'Broker address',
              hintText: '192.168.0.50',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _port,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Port'),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _user,
                  decoration: const InputDecoration(
                    labelText: 'Username',
                    helperText: 'Leave blank if the broker is open',
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _pass,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'Password'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            'HomeDeck listens on the Home Assistant discovery topics, which '
            'Tasmota, ESPHome, Zigbee2MQTT and Shelly publish by default. '
            'No Home Assistant install is needed — only the topic convention '
            'is shared.',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: scheme.outline),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _save,
            child: const Padding(
              padding: EdgeInsets.all(12),
              child: Text('Save & connect'),
            ),
          ),
          if (connector.configured)
            TextButton(
              onPressed: _disconnect,
              child: const Text('Disconnect'),
            ),
        ],
      ),
    );
  }
}
