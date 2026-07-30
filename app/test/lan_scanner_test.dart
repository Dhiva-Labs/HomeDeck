import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:home_deck/connectors/netscan/lan_scanner.dart';

void main() {
  group('wolMagicPacket', () {
    test('builds 102-byte packet: 6xFF + MAC x16', () {
      final packet = wolMagicPacket('aa:bb:cc:dd:ee:ff');

      expect(packet.length, 102);
      expect(packet.sublist(0, 6), everyElement(0xFF));
      final mac = [0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff];
      for (var i = 0; i < 16; i++) {
        expect(packet.sublist(6 + i * 6, 12 + i * 6), mac);
      }
    });

    test('accepts dash-separated MACs', () {
      expect(wolMagicPacket('AA-BB-CC-DD-EE-FF').length, 102);
    });

    test('rejects malformed MACs', () {
      expect(() => wolMagicPacket('nonsense'), throwsArgumentError);
      expect(() => wolMagicPacket('aa:bb:cc'), throwsArgumentError);
    });
  });

  group('nbns', () {
    test('query packet has NBSTAT type and wildcard name', () {
      final packet = nbnsNodeStatusQuery();

      expect(packet.length, 50);
      expect(packet[12], 0x20); // encoded name length
      // '*' = 0x2A -> nibbles 2,A -> 'C','K'
      expect(String.fromCharCodes(packet.sublist(13, 15)), 'CK');
      final data = ByteData.view(packet.buffer);
      expect(data.getUint16(46), 0x0021); // NBSTAT
      expect(data.getUint16(48), 0x0001); // IN
    });

    test('parses workstation name from node status response', () {
      // Minimal synthetic response: header + name section + 1 name entry.
      final response = Uint8List(57 + 18);
      response[56] = 1; // one name
      final name = 'DESKTOP-PC'.padRight(15).codeUnits;
      response.setRange(57, 57 + 15, name);
      response[57 + 15] = 0x00; // workstation suffix
      response[57 + 16] = 0x04; // unique, active (0x0400)
      response[57 + 17] = 0x00;

      expect(parseNbnsNodeStatusResponse(response), 'DESKTOP-PC');
    });

    test('returns null for group names and garbage', () {
      expect(parseNbnsNodeStatusResponse(Uint8List(10)), isNull);

      final response = Uint8List(57 + 18);
      response[56] = 1;
      response.setRange(57, 57 + 15, 'WORKGROUP'.padRight(15).codeUnits);
      response[57 + 15] = 0x00;
      response[57 + 16] = 0x84; // group flag set (0x8400)
      expect(parseNbnsNodeStatusResponse(response), isNull);
    });
  });
}
