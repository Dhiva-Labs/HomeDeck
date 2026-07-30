import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// Ports probed during a sweep. Chosen to (a) prove a host is alive via
/// connect/refuse, and (b) fingerprint what it is.
const probePorts = [
  22, // ssh — computer
  80, // http — web UI
  443, // https — web UI
  445, // smb — computer/nas
  554, // rtsp — camera
  631, // ipp — printer
  1883, // mqtt broker
  5000, // synology/upnp av
  8080, // alt http
  8123, // home assistant
  9100, // jetdirect — printer
];

class HostProbe {
  HostProbe(this.ip);

  final String ip;
  final Set<int> openPorts = {};

  /// True when at least one port answered (accepted or refused). A refused
  /// TCP connection still proves a live IP stack at that address.
  bool alive = false;

  String? hostname;
  String? mac;

  /// Hints from mDNS/SSDP enrichment: name, model, manufacturer, services.
  final Map<String, String> hints = {};
  final Set<String> services = {};
}

/// Pure LAN scanning primitives. No Flutter dependencies — unit-testable.
class LanScanner {
  LanScanner({this.maxInFlight = 64, this.connectTimeout = const Duration(milliseconds: 500)});

  final int maxInFlight;
  final Duration connectTimeout;

  /// Find the local IPv4 interface address and derive the /24 to sweep.
  /// Returns (localIp, subnetPrefix) e.g. ("192.168.1.23", "192.168.1").
  static Future<(String, String)?> localSubnet() async {
    final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
    for (final iface in interfaces) {
      for (final addr in iface.addresses) {
        if (addr.isLoopback) continue;
        final ip = addr.address;
        // Skip link-local (no DHCP) addresses.
        if (ip.startsWith('169.254.')) continue;
        final lastDot = ip.lastIndexOf('.');
        return (ip, ip.substring(0, lastDot));
      }
    }
    return null;
  }

  /// TCP-probe every host in [subnetPrefix].1-254 across [probePorts].
  /// Reports progress (0..1) and discovered live hosts as they appear.
  Future<Map<String, HostProbe>> sweep(
    String subnetPrefix, {
    void Function(double progress)? onProgress,
    void Function(HostProbe host)? onHostFound,
  }) async {
    final probes = <String, HostProbe>{};
    final jobs = <(String, int)>[];
    for (var host = 1; host <= 254; host++) {
      final ip = '$subnetPrefix.$host';
      probes[ip] = HostProbe(ip);
      for (final port in probePorts) {
        jobs.add((ip, port));
      }
    }

    var done = 0;
    final queue = List.of(jobs);
    Future<void> worker() async {
      while (queue.isNotEmpty) {
        final (ip, port) = queue.removeLast();
        final probe = probes[ip]!;
        final wasAlive = probe.alive;
        await _probe(probe, port);
        if (!wasAlive && probe.alive) onHostFound?.call(probe);
        done++;
        if (done % 100 == 0) onProgress?.call(done / jobs.length);
      }
    }

    await Future.wait([for (var i = 0; i < maxInFlight; i++) worker()]);
    onProgress?.call(1.0);

    probes.removeWhere((_, probe) => !probe.alive);
    return probes;
  }

  Future<void> _probe(HostProbe probe, int port) async {
    try {
      final socket = await Socket.connect(
        probe.ip,
        port,
        timeout: connectTimeout,
      );
      probe.alive = true;
      probe.openPorts.add(port);
      socket.destroy();
    } on SocketException catch (e) {
      // "Connection refused" means the host exists but the port is closed.
      if (e.osError?.errorCode == 111 /* ECONNREFUSED */) {
        probe.alive = true;
      }
    } catch (_) {
      // timeout or other error — silent
    }
  }

  /// Read MAC addresses from the kernel ARP table (Linux; works on older
  /// Android too — restricted on Android 10+, where we fall back to ip-keyed
  /// device ids).
  static Future<Map<String, String>> readArpTable() async {
    final result = <String, String>{};
    try {
      final file = File('/proc/net/arp');
      if (await file.exists()) {
        final lines = await file.readAsLines();
        for (final line in lines.skip(1)) {
          final parts = line.split(RegExp(r'\s+'));
          if (parts.length >= 4) {
            final ip = parts[0];
            final mac = parts[3].toLowerCase();
            if (mac != '00:00:00:00:00:00' && mac.contains(':')) {
              result[ip] = mac;
            }
          }
        }
        if (result.isNotEmpty) return result;
      }
    } catch (_) {}
    // Fallback: `ip neigh` (present on desktop Linux and many Androids).
    try {
      final proc = await Process.run('ip', ['neigh', 'show']);
      if (proc.exitCode == 0) {
        for (final line in (proc.stdout as String).split('\n')) {
          final match = RegExp(
                  r'^(\d+\.\d+\.\d+\.\d+)\s.*lladdr\s+([0-9a-f:]{17})')
              .firstMatch(line.toLowerCase());
          if (match != null) result[match.group(1)!] = match.group(2)!;
        }
      }
    } catch (_) {}
    return result;
  }

  /// Reverse-DNS a host, best effort.
  static Future<String?> reverseDns(String ip) async {
    try {
      final addr = await InternetAddress(ip).reverse();
      final host = addr.host;
      if (host.isNotEmpty && host != ip) {
        // Strip trailing domain for readability: "desktop.lan" -> "desktop".
        return host.split('.').first;
      }
    } catch (_) {}
    return null;
  }

  /// NetBIOS node-status query (UDP 137) — recovers Windows machine names.
  static Future<String?> netbiosName(String ip,
      {Duration timeout = const Duration(seconds: 1)}) async {
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.send(nbnsNodeStatusQuery(), InternetAddress(ip), 137);
      final completer = Completer<String?>();
      final sub = socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = socket!.receive();
        if (datagram == null) return;
        final name = parseNbnsNodeStatusResponse(datagram.data);
        if (!completer.isCompleted) completer.complete(name);
      });
      final name =
          await completer.future.timeout(timeout, onTimeout: () => null);
      await sub.cancel();
      return name;
    } catch (_) {
      return null;
    } finally {
      socket?.close();
    }
  }

  /// SSDP M-SEARCH discovery: returns ip -> response headers.
  static Future<Map<String, Map<String, String>>> ssdpSearch(
      {Duration listen = const Duration(seconds: 3)}) async {
    final results = <String, Map<String, String>>{};
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      const msearch = 'M-SEARCH * HTTP/1.1\r\n'
          'HOST: 239.255.255.250:1900\r\n'
          'MAN: "ssdp:discover"\r\n'
          'MX: 2\r\n'
          'ST: ssdp:all\r\n\r\n';
      final target = InternetAddress('239.255.255.250');
      socket.send(msearch.codeUnits, target, 1900);
      socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = socket!.receive();
        if (datagram == null) return;
        final headers = _parseSsdpHeaders(String.fromCharCodes(datagram.data));
        if (headers.isNotEmpty) {
          results[datagram.address.address] = {
            ...?results[datagram.address.address],
            ...headers,
          };
        }
      });
      await Future<void>.delayed(listen);
    } catch (_) {}
    socket?.close();
    return results;
  }

  static Map<String, String> _parseSsdpHeaders(String response) {
    final headers = <String, String>{};
    for (final line in response.split('\r\n').skip(1)) {
      final idx = line.indexOf(':');
      if (idx > 0) {
        headers[line.substring(0, idx).trim().toLowerCase()] =
            line.substring(idx + 1).trim();
      }
    }
    return headers;
  }

  /// Send a Wake-on-LAN magic packet for [mac] to the subnet broadcast.
  static Future<void> wake(String mac, {String? broadcast}) async {
    final packet = wolMagicPacket(mac);
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    socket.broadcastEnabled = true;
    for (final target in [
      ?broadcast,
      '255.255.255.255',
    ]) {
      socket.send(packet, InternetAddress(target), 9);
    }
    socket.close();
  }
}

/// 6×0xFF followed by the MAC repeated 16 times.
Uint8List wolMagicPacket(String mac) {
  if (!RegExp(r'^([0-9a-fA-F]{2}[:\-]){5}[0-9a-fA-F]{2}$').hasMatch(mac)) {
    throw ArgumentError('Invalid MAC address: $mac');
  }
  final macBytes = mac
      .split(RegExp(r'[:\-]'))
      .map((part) => int.parse(part, radix: 16))
      .toList();
  final packet = Uint8List(6 + 16 * 6);
  packet.fillRange(0, 6, 0xFF);
  for (var i = 0; i < 16; i++) {
    packet.setRange(6 + i * 6, 12 + i * 6, macBytes);
  }
  return packet;
}

/// NBNS node status request for the wildcard name "*".
Uint8List nbnsNodeStatusQuery() {
  final packet = Uint8List(50);
  final data = ByteData.view(packet.buffer);
  data.setUint16(0, 0x1D7A); // transaction id (arbitrary)
  data.setUint16(4, 1); // one question
  var offset = 12;
  packet[offset++] = 0x20; // encoded name length
  // First-level encoding of "*" padded with nulls: 0x2A then 15×0x00,
  // each nibble mapped to 'A'+nibble.
  final name = [0x2A, ...List.filled(15, 0)];
  for (final byte in name) {
    packet[offset++] = 0x41 + (byte >> 4);
    packet[offset++] = 0x41 + (byte & 0x0F);
  }
  packet[offset++] = 0x00; // name terminator
  data.setUint16(offset, 0x0021); // NBSTAT
  offset += 2;
  data.setUint16(offset, 0x0001); // IN
  return packet;
}

/// Extract the first workstation name from an NBNS node status response.
String? parseNbnsNodeStatusResponse(Uint8List data) {
  try {
    if (data.length < 57) return null;
    // Header(12) + name(34) + type(2)+class(2)+ttl(4)+rdlength(2) = 56,
    // then number-of-names byte.
    final count = data[56];
    var offset = 57;
    for (var i = 0; i < count; i++) {
      if (offset + 18 > data.length) break;
      final raw = String.fromCharCodes(data.sublist(offset, offset + 15));
      final suffix = data[offset + 15];
      final flags = (data[offset + 16] << 8) | data[offset + 17];
      final isGroup = (flags & 0x8000) != 0;
      final name = raw.trim();
      // Suffix 0x00 unique = workstation name.
      if (suffix == 0x00 && !isGroup && name.isNotEmpty) return name;
      offset += 18;
    }
  } catch (_) {}
  return null;
}
