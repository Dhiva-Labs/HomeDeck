// ignore_for_file: avoid_print
//
// Throwaway verification target: runs a real ONVIF WS-Discovery probe and
// prints what the cameras screen would offer. Run with:
//   dart run tool/camera_probe.dart
import 'package:home_deck/connectors/camera/onvif_service.dart';
import 'package:home_deck/models/camera.dart';

Future<void> main(List<String> args) async {
  print('Probing for ONVIF cameras (4s)…');
  final found = await OnvifService.discover();
  print('${found.length} ONVIF device(s):');
  for (final camera in found) {
    print('  ${camera.name}  host=${camera.host}  xAddr=${camera.xAddr}');
  }

  // Credential-dependent stream resolution: pass user/pass to try it.
  if (args.length >= 2 && found.isNotEmpty) {
    final target = found.first;
    print('\nFetching streams from ${target.host} as ${args[0]}…');
    try {
      final streams = await OnvifService.fetchStreams(
        host: target.host,
        username: args[0],
        password: args[1],
      );
      for (final stream in streams) {
        print('  ${stream.profileName}  ${stream.width}x${stream.height}  '
            '${stream.rtspUrl}');
      }
      final sub = OnvifService.pickSubStream(streams);
      final main = OnvifService.pickMainStream(streams);
      print('  → main:  ${main?.rtspUrl}');
      print('  → sub:   ${sub?.rtspUrl}');
    } catch (e) {
      print('  failed: $e');
    }
  }

  // Verify credential injection without touching the network.
  final camera = Camera(
    name: 'Test',
    streamUrl: 'rtsp://192.168.0.104:554/stream1',
    subStreamUrl: 'rtsp://192.168.0.104:554/stream2',
    username: 'admin',
    password: 'p@ss word',
  );
  print('\nCredential injection:');
  print('  main: ${camera.effectiveUrl()}');
  print('  sub:  ${camera.effectiveUrl(preferSubStream: true)}');
}
