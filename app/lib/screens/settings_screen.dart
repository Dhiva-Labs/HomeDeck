import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../connectors/ha/ha_connector.dart';
import '../connectors/mqtt/mqtt_connector.dart';
import '../services/device_registry.dart';
import '../services/settings_store.dart';
import 'ha_settings_screen.dart';
import 'mqtt_settings_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsStore>();
    final registry = context.watch<DeviceRegistry>();
    final ha = context.watch<HaConnector>();
    final mqtt = context.watch<MqttConnector>();

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          const _SectionHeader('Panel'),
          SwitchListTile(
            title: const Text('Keep screen on'),
            subtitle: const Text('For wall-mounted always-on use'),
            value: settings.keepScreenOn,
            onChanged: (v) {
              settings.keepScreenOn = v;
              WakelockPlus.toggle(enable: v);
            },
          ),
          ListTile(
            title: const Text('Performance mode'),
            subtitle: const Text(
                'Reduces animations and effects for old devices'),
            trailing: SegmentedButton<PerformanceMode>(
              segments: const [
                ButtonSegment(
                    value: PerformanceMode.auto, label: Text('Auto')),
                ButtonSegment(value: PerformanceMode.on, label: Text('On')),
                ButtonSegment(value: PerformanceMode.off, label: Text('Off')),
              ],
              selected: {settings.performanceMode},
              onSelectionChanged: (s) => settings.performanceMode = s.first,
            ),
          ),
          const Divider(),
          const _SectionHeader('Rooms'),
          for (final room in registry.rooms)
            ListTile(
              leading: const Icon(Icons.meeting_room_outlined),
              title: Text(room),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () => registry.removeRoom(room),
              ),
            ),
          ListTile(
            leading: const Icon(Icons.add),
            title: const Text('Add room'),
            onTap: () => _addRoom(context),
          ),
          const Divider(),
          const _SectionHeader('Connections'),
          ListTile(
            leading: const Icon(Icons.home_outlined),
            title: const Text('Home Assistant'),
            subtitle: Text(ha.configured
                ? (ha.statusMessage ?? ha.status.name)
                : 'Not connected'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => const HaSettingsScreen(),
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.hub_outlined),
            title: const Text('MQTT broker'),
            subtitle: Text(mqtt.configured
                ? (mqtt.statusMessage ?? mqtt.status.name)
                : 'Not connected'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => const MqttSettingsScreen(),
              ),
            ),
          ),
          const ListTile(
            leading: Icon(Icons.dns_outlined),
            title: Text('HomeDeck Hub'),
            subtitle: Text('Arrives in the hub build'),
            enabled: false,
          ),
        ],
      ),
    );
  }

  Future<void> _addRoom(BuildContext context) async {
    final registry = context.read<DeviceRegistry>();
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add room'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'e.g. Living room'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) registry.addRoom(name);
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(
          title,
          style: Theme.of(context)
              .textTheme
              .labelLarge
              ?.copyWith(color: Theme.of(context).colorScheme.primary),
        ),
      );
}
