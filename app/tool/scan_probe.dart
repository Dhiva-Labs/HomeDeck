// ignore_for_file: avoid_print
//
// Throwaway verification target: runs a real LAN sweep headlessly and prints
// what the netscan connector would surface. Run with:
//   dart run tool/scan_probe.dart
import 'package:home_deck/connectors/netscan/lan_scanner.dart';

Future<void> main() async {
  final subnet = await LanScanner.localSubnet();
  if (subnet == null) {
    print('No usable IPv4 interface found.');
    return;
  }
  final (localIp, prefix) = subnet;
  print('Local IP: $localIp   sweeping $prefix.1-254');

  final started = DateTime.now();
  final scanner = LanScanner();
  final hosts = await scanner.sweep(
    prefix,
    onProgress: (p) {
      if ((p * 100) % 25 < 1) print('  progress ${(p * 100).round()}%');
    },
  );
  final elapsed = DateTime.now().difference(started);

  final arp = await LanScanner.readArpTable();
  print('\nARP table entries: ${arp.length}');

  print('\n${hosts.length} live hosts in ${elapsed.inSeconds}s:');
  for (final probe in hosts.values) {
    final mac = arp[probe.ip] ?? '—';
    final name = await LanScanner.netbiosName(probe.ip) ??
        await LanScanner.reverseDns(probe.ip) ??
        '';
    final ports = (probe.openPorts.toList()..sort()).join(',');
    print('  ${probe.ip.padRight(16)} $mac  ports=[$ports]  $name');
  }

  final ssdp = await LanScanner.ssdpSearch();
  print('\nSSDP responders: ${ssdp.length}');
  for (final entry in ssdp.entries) {
    print('  ${entry.key}  ${entry.value['server'] ?? ''}');
  }
}
