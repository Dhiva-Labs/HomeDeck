import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../connectors/ha/ha_connector.dart';
import '../connectors/hub/hub_connector.dart';
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
    final hub = context.watch<HubConnector>();

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
          SwitchListTile(
            title: const Text('Dim overnight'),
            subtitle: Text(settings.dimAtNight
                ? 'Dims from ${settings.dimStartHour}:00 to '
                    '${settings.dimEndHour}:00 — tap the screen to wake'
                : 'Keeps a wall-mounted panel from lighting the room'),
            value: settings.dimAtNight,
            onChanged: (v) => settings.dimAtNight = v,
          ),
          if (settings.dimAtNight)
            ListTile(
              title: const Text('Dim window'),
              subtitle: Row(
                children: [
                  Expanded(
                    child: _HourPicker(
                      label: 'From',
                      hour: settings.dimStartHour,
                      onChanged: (h) => settings.dimStartHour = h,
                    ),
                  ),
                  Expanded(
                    child: _HourPicker(
                      label: 'To',
                      hour: settings.dimEndHour,
                      onChanged: (h) => settings.dimEndHour = h,
                    ),
                  ),
                ],
              ),
            ),
          const Divider(),
          const _SectionHeader('Performance'),
          ListTile(
            title: const Text('Performance mode'),
            subtitle: Text(
              settings.performanceMode == PerformanceMode.auto
                  ? 'Auto — ${settings.capabilities.reason}, so effects are '
                      '${settings.lowFx ? 'reduced' : 'on'}'
                  : 'Reduces animations and effects for old devices',
            ),
            isThreeLine: settings.performanceMode == PerformanceMode.auto,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SegmentedButton<PerformanceMode>(
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
          if (settings.capabilities.totalRamMb != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Text(
                'This device: '
                '${(settings.capabilities.totalRamMb! / 1024).toStringAsFixed(1)} GB RAM, '
                '${settings.capabilities.cpuCores} cores'
                '${settings.capabilities.androidSdk != null ? ', API ${settings.capabilities.androidSdk}' : ''}',
                style: Theme.of(context).textTheme.bodySmall,
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
          ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: const Text('HomeDeck Hub'),
            subtitle: Text(hub.configured
                ? (hub.statusMessage ?? hub.status.name)
                : 'Optional — adds 24/7 scanning and camera transcoding'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _configureHub(context, hub),
          ),
        ],
      ),
    );
  }

  Future<void> _configureHub(BuildContext context, HubConnector hub) async {
    final settings = context.read<SettingsStore>();
    final controller = TextEditingController(text: hub.baseUrl ?? '');
    final url = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('HomeDeck Hub'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'The hub is optional. It runs on a Pi or an always-on PC and '
              'adds round-the-clock network scanning, more reliable '
              'Wake-on-LAN, and camera transcoding for weak devices.',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Hub address',
                hintText: '192.168.0.50:8477',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, ''),
            child: const Text('Disconnect'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (url == null) return;
    settings.hubUrl = url;
    await hub.configure(baseUrl: url);
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

class _HourPicker extends StatelessWidget {
  const _HourPicker({
    required this.label,
    required this.hour,
    required this.onChanged,
  });

  final String label;
  final int hour;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) => DropdownButton<int>(
        value: hour,
        isExpanded: true,
        hint: Text(label),
        items: [
          for (var h = 0; h < 24; h++)
            DropdownMenuItem(
                value: h, child: Text('$label ${h.toString().padLeft(2, '0')}:00')),
        ],
        onChanged: (h) => h == null ? null : onChanged(h),
      );
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
