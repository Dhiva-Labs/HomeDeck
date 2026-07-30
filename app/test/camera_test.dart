import 'package:flutter_test/flutter_test.dart';
import 'package:home_deck/connectors/camera/onvif_service.dart';
import 'package:home_deck/models/camera.dart';

OnvifStream stream(String name, int w, int h) => OnvifStream(
      profileName: name,
      profileToken: 'token-$name',
      rtspUrl: 'rtsp://cam/$name',
      width: w,
      height: h,
    );

void main() {
  group('stream selection', () {
    test('sub stream is the smallest profile, main is the largest', () {
      final streams = [
        stream('main', 2560, 1440),
        stream('sub', 640, 360),
        stream('mid', 1280, 720),
      ];

      expect(OnvifService.pickSubStream(streams)!.profileName, 'sub');
      expect(OnvifService.pickMainStream(streams)!.profileName, 'main');
    });

    test('falls back when the camera reports no resolution', () {
      final streams = [
        OnvifStream(
            profileName: 'only',
            profileToken: 't',
            rtspUrl: 'rtsp://cam/only'),
      ];

      expect(OnvifService.pickSubStream(streams)!.profileName, 'only');
      expect(OnvifService.pickMainStream(streams)!.profileName, 'only');
    });

    test('empty profile list yields null rather than throwing', () {
      expect(OnvifService.pickSubStream([]), isNull);
      expect(OnvifService.pickMainStream([]), isNull);
    });
  });

  group('Camera credentials', () {
    test('percent-encodes special characters in credentials', () {
      final camera = Camera(
        name: 'Front door',
        streamUrl: 'rtsp://192.168.0.104:554/stream1',
        username: 'admin',
        password: 'p@ss word',
      );

      expect(camera.effectiveUrl(),
          'rtsp://admin:p%40ss%20word@192.168.0.104:554/stream1');
    });

    test('leaves URLs alone when no username is set', () {
      final camera = Camera(
        name: 'Open cam',
        streamUrl: 'rtsp://192.168.0.104:554/stream1',
      );

      expect(camera.effectiveUrl(), 'rtsp://192.168.0.104:554/stream1');
    });

    test('does not double-inject credentials already in the URL', () {
      final camera = Camera(
        name: 'Preset',
        streamUrl: 'rtsp://bob:secret@192.168.0.104:554/stream1',
        username: 'admin',
        password: 'other',
      );

      expect(camera.effectiveUrl(),
          'rtsp://bob:secret@192.168.0.104:554/stream1');
    });

    test('prefers the sub stream for weak devices, falls back when absent', () {
      final withSub = Camera(
        name: 'Two profiles',
        streamUrl: 'rtsp://cam/main',
        subStreamUrl: 'rtsp://cam/sub',
      );
      final withoutSub =
          Camera(name: 'One profile', streamUrl: 'rtsp://cam/main');

      expect(withSub.effectiveUrl(preferSubStream: true), 'rtsp://cam/sub');
      expect(withSub.effectiveUrl(), 'rtsp://cam/main');
      expect(
          withoutSub.effectiveUrl(preferSubStream: true), 'rtsp://cam/main');
    });

    test('round-trips through JSON', () {
      final camera = Camera(
        name: 'Gate',
        streamUrl: 'rtsp://cam/main',
        subStreamUrl: 'rtsp://cam/sub',
        snapshotUrl: 'http://cam/snap.jpg',
        username: 'admin',
        password: 'pw',
        onvifHost: '192.168.0.104',
        onvifProfileToken: 'profile_1',
        room: 'Outside',
      );

      final restored = Camera.fromJson(camera.toJson());

      expect(restored.id, camera.id);
      expect(restored.name, 'Gate');
      expect(restored.subStreamUrl, 'rtsp://cam/sub');
      expect(restored.snapshotUrl, 'http://cam/snap.jpg');
      expect(restored.supportsPtz, isTrue);
      expect(restored.room, 'Outside');
    });
  });
}
