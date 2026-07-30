import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:multicast_dns/multicast_dns.dart';

import '../../models/device.dart';
import '../connector.dart';

import 'lan_scanner.dart';

/// mDNS service types worth enumerating, with the device kind they imply.
const _mdnsServiceKinds = <String, DeviceKind>{
  '_googlecast._tcp': DeviceKind.tv,
  '_airplay._tcp': DeviceKind.tv,
  '_spotify-connect._tcp': DeviceKind.speaker,
  '_ipp._tcp': DeviceKind.printer,
  '_printer._tcp': DeviceKind.printer,
  '_smb._tcp': DeviceKind.computer,
  '_ssh._tcp': DeviceKind.computer,
  '_home-assistant._tcp': DeviceKind.unknown,
  '_hap._tcp': DeviceKind.unknown, // HomeKit accessory
  '_http._tcp': DeviceKind.unknown,
};

/// Discovers everything with an IP on the local subnet — smart or not —
/// via TCP sweep, ARP, reverse DNS, NetBIOS, SSDP and mDNS.
class NetscanConnector extends Connector {
  NetscanConnector(super.registry);

  @override
  String get id => 'netscan';

  @override
  String get label => 'Network scan';

  final LanScanner _scanner = LanScanner();
  Timer? _presenceTimer;
  bool _scanning = false;

  double _progress = 0;
  double get progress => _progress;
  bool get scanning => _scanning;

  String? _localIp;
  String? _gatewayIp;

  @override
  Future<void> start() async {
    setStatus(ConnectorStatus.connected);
    _presenceTimer ??= Timer.periodic(
      const Duration(seconds: 60),
      (_) => _pollPresence(),
    );
    // First-run presence check for cached devices.
    unawaited(_pollPresence());
  }

  @override
  Future<void> stop() async {
    _presenceTimer?.cancel();
    _presenceTimer = null;
    setStatus(ConnectorStatus.disabled);
  }

  @override
  Future<void> refresh() => scan();

  /// Full discovery sweep. Safe to call from the UI; no-ops if running.
  Future<void> scan() async {
    if (_scanning) return;
    _scanning = true;
    _progress = 0;
    setStatus(ConnectorStatus.starting, 'Scanning network…');

    try {
      final subnet = await LanScanner.localSubnet();
      if (subnet == null) {
        setStatus(ConnectorStatus.error, 'No network connection found');
        return;
      }
      final (localIp, prefix) = subnet;
      _localIp = localIp;
      _gatewayIp = await _findGateway();

      // Kick off passive discoveries in parallel with the sweep.
      final ssdpFuture = LanScanner.ssdpSearch();
      final mdnsFuture = _mdnsDiscover();

      final hosts = await _scanner.sweep(
        prefix,
        onProgress: (p) {
          _progress = p;
          notifyListeners();
        },
        onHostFound: (probe) {
          // Surface hosts as they appear rather than at the end.
          registry.upsertAll([_toDevice(probe)]);
        },
      );

      // Enrich with MACs, names and UPnP/mDNS metadata.
      final arp = await LanScanner.readArpTable();
      final ssdp = await ssdpFuture;
      final mdns = await mdnsFuture;

      for (final probe in hosts.values) {
        probe.mac = arp[probe.ip];
        final mdnsInfo = mdns[probe.ip];
        if (mdnsInfo != null) {
          probe.hints.addAll(mdnsInfo.hints);
          probe.services.addAll(mdnsInfo.services);
        }
        final ssdpHeaders = ssdp[probe.ip];
        if (ssdpHeaders != null) {
          probe.hints['server'] = ssdpHeaders['server'] ?? '';
          final location = ssdpHeaders['location'];
          if (location != null) {
            final desc = await _fetchUpnpDescription(location);
            probe.hints.addAll(desc);
          }
        }
        probe.hostname ??= probe.hints['name'] ??
            await LanScanner.netbiosName(probe.ip) ??
            await LanScanner.reverseDns(probe.ip);
      }

      registry.upsertAll(hosts.values.map(_toDevice));

      // Anything previously known on this connector that didn't answer is
      // offline now.
      final seen = hosts.values.map((probe) => _idFor(probe)).toSet();
      for (final device in registry.byConnector(id)) {
        if (!seen.contains(device.id)) {
          registry.updateState(device.id, {}, online: false);
        }
      }

      setStatus(ConnectorStatus.connected,
          '${hosts.length} devices found');
    } catch (e) {
      setStatus(ConnectorStatus.error, 'Scan failed: $e');
    } finally {
      _scanning = false;
      _progress = 0;
      notifyListeners();
    }
  }

  @override
  Future<void> invoke(Device device, DeviceAction action) async {
    switch (action.name) {
      case 'wake':
        final mac = device.mac;
        if (mac == null) return;
        final prefix = _localIp?.substring(0, _localIp!.lastIndexOf('.'));
        await LanScanner.wake(mac,
            broadcast: prefix == null ? null : '$prefix.255');
      case 'ping':
        final online = await _isAlive(device.ip);
        registry.updateState(device.id, {}, online: online);
      default:
      // Non-IoT hosts have no other verbs.
    }
  }

  // ---- internals ------------------------------------------------------------

  String _idFor(HostProbe probe) =>
      probe.mac != null ? '$id:${probe.mac}' : '$id:ip-${probe.ip}';

  Device _toDevice(HostProbe probe) {
    final isGateway = probe.ip == _gatewayIp;
    final isSelf = probe.ip == _localIp;
    final kind = _guessKind(probe, isGateway: isGateway, isSelf: isSelf);

    final capabilities = <DeviceCapability>{
      DeviceCapability.ping,
      if (probe.mac != null) DeviceCapability.wake,
      if (probe.openPorts.any(const {80, 443, 8080, 8123}.contains))
        DeviceCapability.openUrl,
    };

    String? webUrl;
    if (capabilities.contains(DeviceCapability.openUrl)) {
      final port = [443, 80, 8123, 8080]
          .firstWhere(probe.openPorts.contains, orElse: () => 80);
      final scheme = port == 443 ? 'https' : 'http';
      webUrl =
          '$scheme://${probe.ip}${port == 80 || port == 443 ? '' : ':$port'}';
    }

    return Device(
      id: _idFor(probe),
      connectorId: id,
      name: probe.hostname ??
          (isGateway
              ? 'Router'
              : isSelf
                  ? 'This device'
                  : 'Device .${probe.ip.split('.').last}'),
      kind: kind,
      online: true,
      attrs: {
        'ip': probe.ip,
        'mac': ?probe.mac,
        'ports': probe.openPorts.toList()..sort(),
        'webUrl': ?webUrl,
        'model': ?probe.hints['model'],
        'manufacturer': ?probe.hints['manufacturer'],
        if (probe.openPorts.contains(8123)) 'haCandidate': true,
        if (probe.openPorts.contains(1883)) 'mqttCandidate': true,
        if (probe.openPorts.contains(554)) 'rtspCandidate': true,
      },
      capabilities: capabilities,
    );
  }

  DeviceKind _guessKind(HostProbe probe,
      {required bool isGateway, required bool isSelf}) {
    if (isGateway) return DeviceKind.router;
    if (isSelf) return DeviceKind.tablet;
    for (final service in probe.services) {
      final kind = _mdnsServiceKinds[service];
      if (kind != null && kind != DeviceKind.unknown) return kind;
    }
    final deviceType = probe.hints['deviceType'] ?? '';
    if (deviceType.contains('InternetGatewayDevice')) return DeviceKind.router;
    if (deviceType.contains('MediaRenderer')) return DeviceKind.tv;
    final ports = probe.openPorts;
    if (ports.contains(9100) || ports.contains(631)) return DeviceKind.printer;
    if (ports.contains(554)) return DeviceKind.camera;
    if (ports.contains(5000) && ports.contains(445)) return DeviceKind.nas;
    if (ports.contains(22) || ports.contains(445)) return DeviceKind.computer;
    return DeviceKind.unknown;
  }

  Future<bool> _isAlive(String? ip) async {
    if (ip == null) return false;
    for (final port in [80, 443, 22, 445]) {
      try {
        final socket = await Socket.connect(ip, port,
            timeout: const Duration(milliseconds: 700));
        socket.destroy();
        return true;
      } on SocketException catch (e) {
        if (e.osError?.errorCode == 111) return true; // refused = alive
      } catch (_) {}
    }
    return false;
  }

  Future<void> _pollPresence() async {
    for (final device in registry.byConnector(id)) {
      final online = await _isAlive(device.ip);
      if (online != device.online) {
        registry.updateState(device.id, {}, online: online);
      }
    }
  }

  Future<String?> _findGateway() async {
    try {
      final proc = await Process.run('ip', ['route', 'show', 'default']);
      final match = RegExp(r'default via (\d+\.\d+\.\d+\.\d+)')
          .firstMatch(proc.stdout as String);
      return match?.group(1);
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, _MdnsInfo>> _mdnsDiscover() async {
    final results = <String, _MdnsInfo>{};
    MDnsClient? client;
    try {
      client = MDnsClient(rawDatagramSocketFactory:
          (dynamic host, int port, {bool? reuseAddress, bool? reusePort, int? ttl}) {
        return RawDatagramSocket.bind(host, port,
            reuseAddress: true, reusePort: true, ttl: ttl ?? 255);
      });
      await client.start();
      for (final entry in _mdnsServiceKinds.entries) {
        final type = '${entry.key}.local';
        await for (final ptr in client
            .lookup<PtrResourceRecord>(
                ResourceRecordQuery.serverPointer(type))
            .timeout(const Duration(seconds: 1), onTimeout: (sink) => sink.close())) {
          await for (final srv in client
              .lookup<SrvResourceRecord>(
                  ResourceRecordQuery.service(ptr.domainName))
              .timeout(const Duration(milliseconds: 800),
                  onTimeout: (sink) => sink.close())) {
            await for (final a in client
                .lookup<IPAddressResourceRecord>(
                    ResourceRecordQuery.addressIPv4(srv.target))
                .timeout(const Duration(milliseconds: 800),
                    onTimeout: (sink) => sink.close())) {
              final ip = a.address.address;
              final info = results.putIfAbsent(ip, _MdnsInfo.new);
              info.services.add(entry.key);
              // "Living Room TV._googlecast._tcp.local" -> "Living Room TV"
              final instance = ptr.domainName.split('.$type').first;
              info.hints['name'] ??= instance;
            }
          }
        }
      }
    } catch (_) {
      // mDNS is best-effort (may be blocked, or the port busy with avahi).
    } finally {
      client?.stop();
    }
    return results;
  }

  Future<Map<String, String>> _fetchUpnpDescription(String location) async {
    try {
      final response = await http
          .get(Uri.parse(location))
          .timeout(const Duration(seconds: 2));
      if (response.statusCode != 200) return {};
      String? tag(String name) =>
          RegExp('<$name>([^<]+)</$name>').firstMatch(response.body)?.group(1);
      return {
        if (tag('friendlyName') != null) 'name': tag('friendlyName')!,
        if (tag('manufacturer') != null) 'manufacturer': tag('manufacturer')!,
        if (tag('modelName') != null) 'model': tag('modelName')!,
        if (tag('deviceType') != null) 'deviceType': tag('deviceType')!,
      };
    } catch (_) {
      return {};
    }
  }
}

class _MdnsInfo {
  final Map<String, String> hints = {};
  final Set<String> services = {};
}
