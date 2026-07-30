import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../connectors/netscan/netscan_connector.dart';
import '../models/device.dart';
import '../services/connectors_service.dart';
import '../services/device_registry.dart';
import '../widgets/device_tile.dart';

/// Flat list of everything known, with per-device detail/edit sheet and a
/// live network scan.
class DevicesScreen extends StatelessWidget {
  const DevicesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final registry = context.watch<DeviceRegistry>();
    final netscan = context.watch<NetscanConnector>();
    final devices = registry.devices;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Devices'),
        bottom: netscan.scanning
            ? PreferredSize(
                preferredSize: const Size.fromHeight(4),
                child: LinearProgressIndicator(
                  value: netscan.progress == 0 ? null : netscan.progress,
                ),
              )
            : null,
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: netscan.scanning ? null : () => netscan.scan(),
        icon: netscan.scanning
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.radar),
        label: Text(netscan.scanning ? 'Scanning…' : 'Scan network'),
      ),
      body: devices.isEmpty
          ? Center(
              child: Text(
                netscan.scanning
                    ? 'Looking for devices…'
                    : 'Nothing here yet.\nTap "Scan network" to look for devices.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).colorScheme.outline),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 88),
              itemCount: devices.length,
              itemBuilder: (context, i) {
                final device = devices[i];
                return DeviceTile(
                  device: device,
                  onTap: () => _showDetail(context, device),
                );
              },
            ),
    );
  }

  void _showDetail(BuildContext context, Device device) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => DeviceDetailSheet(deviceId: device.id),
    );
  }
}

/// Bottom sheet: actions, rename, assign room, change kind, hide/forget.
class DeviceDetailSheet extends StatelessWidget {
  const DeviceDetailSheet({super.key, required this.deviceId});

  final String deviceId;

  @override
  Widget build(BuildContext context) {
    final registry = context.watch<DeviceRegistry>();
    final device = registry.byId(deviceId);
    if (device == null) return const SizedBox.shrink();

    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          Row(
            children: [
              Icon(iconForKind(device.kind), size: 32),
              const SizedBox(width: 12),
              Expanded(
                child: Text(device.name,
                    style: Theme.of(context).textTheme.titleLarge),
              ),
              IconButton(
                icon: const Icon(Icons.edit_outlined),
                tooltip: 'Rename',
                onPressed: () => _rename(context, device),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (device.ip != null) Chip(label: Text(device.ip!)),
              if (device.mac != null) Chip(label: Text(device.mac!)),
              Chip(label: Text(device.online ? 'Online' : 'Offline')),
              if (device.attrs['model'] != null)
                Chip(label: Text('${device.attrs['model']}')),
            ],
          ),
          const SizedBox(height: 12),
          _ActionRow(device: device),
          const SizedBox(height: 16),
          DropdownMenu<String?>(
            label: const Text('Room'),
            initialSelection: device.room,
            expandedInsets: EdgeInsets.zero,
            dropdownMenuEntries: [
              const DropdownMenuEntry<String?>(value: null, label: 'No room'),
              for (final room in registry.rooms)
                DropdownMenuEntry<String?>(value: room, label: room),
            ],
            onSelected: (room) => registry.assignRoom(device.id, room),
          ),
          const SizedBox(height: 12),
          DropdownMenu<DeviceKind>(
            label: const Text('Type'),
            initialSelection: device.kind,
            expandedInsets: EdgeInsets.zero,
            dropdownMenuEntries: [
              for (final kind in DeviceKind.values)
                DropdownMenuEntry(value: kind, label: kind.name),
            ],
            onSelected: (kind) =>
                kind == null ? null : registry.setKind(device.id, kind),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () {
                  registry.hide(device.id);
                  Navigator.pop(context);
                },
                child: const Text('Hide'),
              ),
              TextButton(
                onPressed: () {
                  registry.forget(device.id);
                  Navigator.pop(context);
                },
                child: const Text('Forget'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _rename(BuildContext context, Device device) async {
    final registry = context.read<DeviceRegistry>();
    final controller = TextEditingController(text: device.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename device'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) registry.rename(device.id, name);
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({required this.device});

  final Device device;

  @override
  Widget build(BuildContext context) {
    final connectors = context.read<ConnectorsService>();
    final messenger = ScaffoldMessenger.of(context);

    return Wrap(
      spacing: 8,
      children: [
        if (device.can(DeviceCapability.wake))
          FilledButton.tonalIcon(
            icon: const Icon(Icons.power_settings_new),
            label: const Text('Wake'),
            onPressed: () async {
              await connectors.invoke(device, const DeviceAction('wake'));
              messenger.showSnackBar(
                SnackBar(content: Text('Wake-on-LAN sent to ${device.name}')),
              );
            },
          ),
        if (device.can(DeviceCapability.ping))
          FilledButton.tonalIcon(
            icon: const Icon(Icons.network_ping),
            label: const Text('Ping'),
            onPressed: () =>
                connectors.invoke(device, const DeviceAction('ping')),
          ),
        if (device.attrs['webUrl'] != null)
          FilledButton.tonalIcon(
            icon: const Icon(Icons.open_in_browser),
            label: const Text('Web UI'),
            onPressed: () => launchUrl(
              Uri.parse(device.attrs['webUrl'] as String),
              mode: LaunchMode.externalApplication,
            ),
          ),
      ],
    );
  }
}
