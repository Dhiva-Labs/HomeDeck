import 'dart:async';
import 'dart:developer' as developer;

import 'package:easy_onvif/onvif.dart';
import 'package:easy_onvif/probe.dart';

/// A camera found on the LAN via WS-Discovery, before authentication.
class DiscoveredCamera {
  DiscoveredCamera({
    required this.name,
    required this.host,
    required this.xAddr,
  });

  final String name;
  final String host; // host[:port] for the ONVIF service
  final String xAddr;
}

/// One selectable stream (profile) on an authenticated ONVIF camera.
class OnvifStream {
  OnvifStream({
    required this.profileName,
    required this.profileToken,
    required this.rtspUrl,
    this.width,
    this.height,
  });

  final String profileName;
  final String profileToken;
  final String rtspUrl;
  final int? width;
  final int? height;

  int get pixels => (width ?? 0) * (height ?? 0);
}

class OnvifService {
  /// Multicast WS-Discovery probe. Works for the vast majority of IP camera
  /// brands (Hikvision, Dahua, Axis, Reolink, TP-Link, Uniview, …).
  ///
  /// Runs inside a guarded zone: "any brand" means some responder on the LAN
  /// will eventually reply with SOAP the parser chokes on, and easy_onvif
  /// throws from inside its own datagram listener — an async error no
  /// try/catch here could otherwise catch, which would take the app down.
  static Future<List<DiscoveredCamera>> discover({
    Duration timeout = const Duration(seconds: 4),
  }) {
    final completer = Completer<List<DiscoveredCamera>>();
    final probe = MulticastProbe(timeout: timeout.inSeconds);

    void finish() {
      if (completer.isCompleted) return;
      completer.complete(_mapDevices(probe));
    }

    runZonedGuarded(
      () async {
        try {
          await probe.probe();
        } catch (e) {
          developer.log('ONVIF discovery probe failed: $e');
        }
        finish();
      },
      (error, stack) {
        // A non-conforming responder poisoned the parse. Keep whatever
        // well-formed devices already answered.
        developer.log('ONVIF discovery: ignoring malformed reply: $error');
      },
    );

    // Backstop: if the zone error aborted the probe's own await chain, still
    // return on time rather than hanging the UI forever.
    return completer.future.timeout(
      timeout + const Duration(seconds: 2),
      onTimeout: () => _mapDevices(probe),
    );
  }

  static List<DiscoveredCamera> _mapDevices(MulticastProbe probe) {
    final results = <DiscoveredCamera>[];
    for (final device in probe.onvifDevices) {
      final uri = Uri.tryParse(device.xAddr);
      if (uri == null || uri.host.isEmpty) continue;
      final host =
          uri.hasPort && uri.port != 80 ? '${uri.host}:${uri.port}' : uri.host;
      final name = device.name.isNotEmpty
          ? device.name
          : (device.hardware.isNotEmpty ? device.hardware : uri.host);
      results.add(
          DiscoveredCamera(name: name, host: host, xAddr: device.xAddr));
    }
    return results;
  }

  /// Authenticate against a camera's ONVIF endpoint and resolve every media
  /// profile to an RTSP URL (typically a main stream plus a low-res sub
  /// stream, which is what old tablets should be playing).
  static Future<List<OnvifStream>> fetchStreams({
    required String host,
    required String username,
    required String password,
  }) async {
    final onvif = await Onvif.connect(
      host: host,
      username: username,
      password: password,
    );

    final streams = <OnvifStream>[];
    final profiles = await onvif.media.getProfiles();
    for (final profile in profiles) {
      try {
        final uri = await onvif.media.getStreamUri(profile.token);
        final resolution =
            profile.videoEncoderConfiguration?.resolution;
        streams.add(OnvifStream(
          profileName: profile.name,
          profileToken: profile.token,
          rtspUrl: uri,
          width: resolution?.width,
          height: resolution?.height,
        ));
      } catch (e) {
        developer.log('ONVIF: profile ${profile.name} has no stream URI: $e');
      }
    }
    return streams;
  }

  /// Pick the stream an old panel should play: the smallest profile that is
  /// still usable (the "sub stream"), falling back to whatever exists.
  static OnvifStream? pickSubStream(List<OnvifStream> streams) {
    if (streams.isEmpty) return null;
    final sized = streams.where((s) => s.pixels > 0).toList()
      ..sort((a, b) => a.pixels.compareTo(b.pixels));
    return sized.isNotEmpty ? sized.first : streams.last;
  }

  /// Pick the best-quality stream for fullscreen viewing on capable hardware.
  static OnvifStream? pickMainStream(List<OnvifStream> streams) {
    if (streams.isEmpty) return null;
    final sized = streams.where((s) => s.pixels > 0).toList()
      ..sort((a, b) => b.pixels.compareTo(a.pixels));
    return sized.isNotEmpty ? sized.first : streams.first;
  }
}
