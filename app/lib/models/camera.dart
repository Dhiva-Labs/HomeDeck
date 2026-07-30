import 'package:uuid/uuid.dart';

/// A single camera source. IP cameras arrive as an RTSP endpoint (entered
/// manually or resolved via ONVIF); analog cameras arrive the same way once
/// a DVR or encoder exposes them as a stream; Home Assistant cameras arrive
/// as an HTTP stream/snapshot pair.
class Camera {
  Camera({
    String? id,
    required this.name,
    required this.streamUrl,
    this.subStreamUrl,
    this.snapshotUrl,
    this.username = '',
    this.password = '',
    this.useTcp = true,
    this.onvifHost,
    this.onvifProfileToken,
    this.room,
    this.enabled = true,
  }) : id = id ?? const Uuid().v4();

  final String id;
  String name;

  /// Full-quality stream URL, credentials NOT embedded.
  /// e.g. rtsp://192.168.0.104:554/Streaming/Channels/101
  String streamUrl;

  /// Low-resolution stream, preferred on grids and weak hardware.
  String? subStreamUrl;

  /// Still-image endpoint, used for grid thumbnails so N cameras don't mean
  /// N simultaneous video decodes.
  String? snapshotUrl;

  String username;
  String password;

  /// RTSP over TCP is far more reliable across brands; UDP is lower latency.
  bool useTcp;

  String? onvifHost;

  /// ONVIF media profile token — required for PTZ commands.
  String? onvifProfileToken;

  String? room;
  bool enabled;

  bool get supportsPtz => onvifHost != null && onvifProfileToken != null;

  /// Stream URL with credentials injected (rtsp://user:pass@host/…).
  String urlWithCredentials(String url) {
    if (username.isEmpty) return url;
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return url;
    if (uri.userInfo.isNotEmpty) return url; // already embedded
    final user = Uri.encodeComponent(username);
    final pass = Uri.encodeComponent(password);
    return uri
        .replace(userInfo: password.isEmpty ? user : '$user:$pass')
        .toString();
  }

  /// The URL to play, honouring [preferSubStream] for old panels.
  String effectiveUrl({bool preferSubStream = false}) => urlWithCredentials(
        preferSubStream ? (subStreamUrl ?? streamUrl) : streamUrl,
      );

  String? get effectiveSnapshotUrl =>
      snapshotUrl == null ? null : urlWithCredentials(snapshotUrl!);

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'streamUrl': streamUrl,
        'subStreamUrl': subStreamUrl,
        'snapshotUrl': snapshotUrl,
        'username': username,
        'password': password,
        'useTcp': useTcp,
        'onvifHost': onvifHost,
        'onvifProfileToken': onvifProfileToken,
        'room': room,
        'enabled': enabled,
      };

  factory Camera.fromJson(Map<String, dynamic> json) => Camera(
        id: json['id'] as String?,
        name: json['name'] as String? ?? 'Camera',
        streamUrl: json['streamUrl'] as String? ?? '',
        subStreamUrl: json['subStreamUrl'] as String?,
        snapshotUrl: json['snapshotUrl'] as String?,
        username: json['username'] as String? ?? '',
        password: json['password'] as String? ?? '',
        useTcp: json['useTcp'] as bool? ?? true,
        onvifHost: json['onvifHost'] as String?,
        onvifProfileToken: json['onvifProfileToken'] as String?,
        room: json['room'] as String?,
        enabled: json['enabled'] as bool? ?? true,
      );
}
