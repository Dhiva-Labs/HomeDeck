import 'package:flutter/material.dart';

import '../models/device.dart';

IconData iconForKind(DeviceKind kind) => switch (kind) {
      DeviceKind.light => Icons.lightbulb_outline,
      DeviceKind.outlet => Icons.power_outlined,
      DeviceKind.switch_ => Icons.toggle_on_outlined,
      DeviceKind.sensor => Icons.sensors,
      DeviceKind.climate => Icons.thermostat,
      DeviceKind.camera => Icons.videocam_outlined,
      DeviceKind.media => Icons.play_circle_outline,
      DeviceKind.speaker => Icons.speaker_outlined,
      DeviceKind.tv => Icons.tv_outlined,
      DeviceKind.computer => Icons.computer_outlined,
      DeviceKind.phone => Icons.smartphone_outlined,
      DeviceKind.tablet => Icons.tablet_outlined,
      DeviceKind.printer => Icons.print_outlined,
      DeviceKind.nas => Icons.storage_outlined,
      DeviceKind.router => Icons.router_outlined,
      DeviceKind.scene => Icons.auto_awesome_outlined,
      DeviceKind.unknown => Icons.devices_other_outlined,
    };

/// Compact tappable tile representing one device on the dashboard/devices
/// screens. Renders a toggle when the device supports it.
class DeviceTile extends StatelessWidget {
  const DeviceTile({
    super.key,
    required this.device,
    this.onTap,
    this.onToggle,
  });

  final Device device;
  final VoidCallback? onTap;
  final ValueChanged<bool>? onToggle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = device.online && device.isOn;

    return Card(
      color: active ? scheme.primaryContainer : null,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Icon(
                iconForKind(device.kind),
                color: device.online
                    ? (active ? scheme.onPrimaryContainer : scheme.primary)
                    : scheme.outline,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      device.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    Text(
                      _subtitle(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: scheme.outline),
                    ),
                  ],
                ),
              ),
              if (device.can(DeviceCapability.toggle) && onToggle != null)
                Switch(
                  value: device.isOn,
                  onChanged: device.online ? onToggle : null,
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _subtitle() {
    if (!device.online) return 'Offline';
    final value = device.state['value'];
    final unit = device.attrs['unit'] ?? '';
    if (value != null) return '$value$unit';
    if (device.ip != null) return device.ip!;
    return device.kind == DeviceKind.unknown ? device.connectorId : device.kind.name;
  }
}
