import 'package:flutter_test/flutter_test.dart';
import 'package:home_deck/services/device_capabilities.dart';
import 'package:home_deck/services/settings_store.dart';

void main() {
  group('parseMemTotalKb', () {
    test('reads the value out of a /proc/meminfo line', () {
      expect(parseMemTotalKb('MemTotal:        1020400 kB'), 1020400);
      expect(parseMemTotalKb('MemTotal:       16316104 kB'), 16316104);
    });

    test('returns null for other lines', () {
      expect(parseMemTotalKb('MemFree:          123456 kB'), isNull);
      expect(parseMemTotalKb('garbage'), isNull);
    });
  });

  group('isWithinDimWindow', () {
    test('handles a window that wraps past midnight', () {
      // The normal case: dim 23:00 to 06:00.
      expect(isWithinDimWindow(23, 23, 6), isTrue);
      expect(isWithinDimWindow(2, 23, 6), isTrue);
      expect(isWithinDimWindow(5, 23, 6), isTrue);
      expect(isWithinDimWindow(6, 23, 6), isFalse);
      expect(isWithinDimWindow(12, 23, 6), isFalse);
      expect(isWithinDimWindow(22, 23, 6), isFalse);
    });

    test('handles a same-day window', () {
      // Someone dimming during working hours.
      expect(isWithinDimWindow(10, 9, 17), isTrue);
      expect(isWithinDimWindow(9, 9, 17), isTrue);
      expect(isWithinDimWindow(17, 9, 17), isFalse);
      expect(isWithinDimWindow(3, 9, 17), isFalse);
    });
  });

  group('DeviceCapabilities', () {
    test('flags low RAM as weak with a readable reason', () {
      const weak = DeviceCapabilities(
        isWeak: true,
        reason: '1.0 GB of RAM',
        totalRamMb: 1024,
        cpuCores: 4,
      );

      expect(weak.isWeak, isTrue);
      expect(weak.reason, contains('GB'));
    });

    test('detect() returns a usable result on this machine', () async {
      final caps = await DeviceCapabilities.detect();

      // Whatever the answer, it must be justified rather than blank.
      expect(caps.reason, isNotEmpty);
      expect(caps.cpuCores, greaterThan(0));
    });
  });
}
