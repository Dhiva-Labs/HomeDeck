import 'dart:io';

import 'package:flutter/foundation.dart';

/// What this panel's hardware can reasonably handle.
///
/// Old phones are the target, so the app decides for itself rather than
/// making the user guess. Everything here is read once at startup.
class DeviceCapabilities {
  const DeviceCapabilities({
    required this.isWeak,
    required this.reason,
    this.totalRamMb,
    this.androidSdk,
    this.cpuCores,
  });

  /// True when the app should drop to reduced-effects mode by default.
  final bool isWeak;

  /// Human-readable justification, shown in Settings so the choice isn't
  /// mysterious.
  final String reason;

  final int? totalRamMb;
  final int? androidSdk;
  final int? cpuCores;

  static Future<DeviceCapabilities> detect() async {
    final cores = Platform.numberOfProcessors;
    final ram = await _totalRamMb();
    final sdk = await _androidSdk();

    // Thresholds picked around what actually struggles: a 1 GB Android 5
    // tablet drops frames on shadows and page transitions; 2 GB and up
    // generally does not.
    if (ram != null && ram < 1536) {
      return DeviceCapabilities(
        isWeak: true,
        reason: '${(ram / 1024).toStringAsFixed(1)} GB of RAM',
        totalRamMb: ram,
        androidSdk: sdk,
        cpuCores: cores,
      );
    }
    if (sdk != null && sdk < 26) {
      return DeviceCapabilities(
        isWeak: true,
        reason: 'Android ${_androidRelease(sdk)}',
        totalRamMb: ram,
        androidSdk: sdk,
        cpuCores: cores,
      );
    }
    if (cores <= 2) {
      return DeviceCapabilities(
        isWeak: true,
        reason: '$cores CPU cores',
        totalRamMb: ram,
        androidSdk: sdk,
        cpuCores: cores,
      );
    }

    return DeviceCapabilities(
      isWeak: false,
      reason: 'Hardware looks capable',
      totalRamMb: ram,
      androidSdk: sdk,
      cpuCores: cores,
    );
  }

  /// Total RAM in MB from /proc/meminfo (present on Linux and Android).
  static Future<int?> _totalRamMb() async {
    try {
      final file = File('/proc/meminfo');
      if (!await file.exists()) return null;
      final lines = await file.readAsLines();
      for (final line in lines) {
        if (!line.startsWith('MemTotal:')) continue;
        return parseMemTotalKb(line) == null
            ? null
            : (parseMemTotalKb(line)! / 1024).round();
      }
    } catch (e) {
      debugPrint('DeviceCapabilities: could not read memory: $e');
    }
    return null;
  }

  /// Android API level via the build property, or null off Android.
  static Future<int?> _androidSdk() async {
    if (!Platform.isAndroid) return null;
    try {
      final result =
          await Process.run('getprop', ['ro.build.version.sdk']);
      return int.tryParse((result.stdout as String).trim());
    } catch (_) {
      return null;
    }
  }

  static String _androidRelease(int sdk) => switch (sdk) {
        <= 21 => '5.0',
        22 => '5.1',
        23 => '6.0',
        24 => '7.0',
        25 => '7.1',
        _ => 'API $sdk',
      };
}

/// Pull the kilobyte figure out of a `/proc/meminfo` MemTotal line.
int? parseMemTotalKb(String line) {
  final match = RegExp(r'MemTotal:\s+(\d+)\s+kB').firstMatch(line);
  return match == null ? null : int.tryParse(match.group(1)!);
}
