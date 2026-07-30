import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/device.dart';
import '../services/connectors_service.dart';
import '../services/device_registry.dart';
import '../widgets/device_tile.dart';

/// Rooms-first overview: each room is a section of device tiles; devices
/// without a room are grouped under "Unassigned".
class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final registry = context.watch<DeviceRegistry>();
    final devices = registry.devices;

    if (devices.isEmpty) {
      return _EmptyDashboard();
    }

    final sections = <String, List<Device>>{};
    for (final room in registry.rooms) {
      final inRoom = registry.byRoom(room);
      if (inRoom.isNotEmpty) sections[room] = inRoom;
    }
    final unassigned = registry.byRoom(null);
    if (unassigned.isNotEmpty) sections['Unassigned'] = unassigned;

    return CustomScrollView(
      slivers: [
        const SliverAppBar(title: Text('HomeDeck'), floating: true),
        for (final entry in sections.entries) ...[
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            sliver: SliverToBoxAdapter(
              child: Text(
                entry.key,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 280,
                mainAxisExtent: 64,
                crossAxisSpacing: 4,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, i) {
                  final device = entry.value[i];
                  return DeviceTile(
                    device: device,
                    onToggle: (_) => _toggle(context, device),
                  );
                },
                childCount: entry.value.length,
              ),
            ),
          ),
        ],
        const SliverPadding(padding: EdgeInsets.only(bottom: 24)),
      ],
    );
  }

  void _toggle(BuildContext context, Device device) {
    context.read<ConnectorsService>().invoke(device, const DeviceAction('toggle'));
  }
}

class _EmptyDashboard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.home_outlined, size: 72, color: scheme.outline),
            const SizedBox(height: 16),
            Text(
              'No devices yet',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              'Scan your network from the Devices tab to find computers, '
              'cameras and smart devices, or connect Home Assistant in '
              'Settings.',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: scheme.outline),
            ),
          ],
        ),
      ),
    );
  }
}
