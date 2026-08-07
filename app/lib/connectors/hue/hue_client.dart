import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart' as io_client;

/// Result of a bridge pairing attempt — see [pairWithBridge] in
/// [HueClient.pair].
typedef HuePairResult = ({bool ok, String? applicationKey, String message});

/// Thin CLIP v2 REST client for one paired Hue bridge.
///
/// The bridge serves plain HTTPS on the LAN with a self-signed certificate
/// (there is no CA a phone would trust for a device with no public
/// hostname), so the underlying [HttpClient] accepts that one certificate —
/// pinned to this bridge's IP specifically, never to "any host", which would
/// silently defeat certificate checking for every other HTTPS call in the
/// app that happens to share this client.
class HueClient {
  HueClient({required this.bridgeIp, required this.applicationKey})
      : _http = io_client.IOClient(
          HttpClient()
            ..badCertificateCallback = (cert, host, port) => host == bridgeIp,
        );

  final String bridgeIp;
  final String applicationKey;
  final http.Client _http;

  Uri _uri(String path) => Uri.parse('https://$bridgeIp$path');

  Map<String, String> get _headers => {'hue-application-key': applicationKey};

  /// GET `/clip/v2/resource/<type>` (e.g. "light", "device", "room",
  /// "scene"). Returns the `data` array; CLIP v2 wraps every response the
  /// same way regardless of resource type.
  Future<List<dynamic>> getResources(String type) async {
    final response = await _http
        .get(_uri('/clip/v2/resource/$type'), headers: _headers)
        .timeout(const Duration(seconds: 8));
    _checkOk(response);
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return (json['data'] as List?) ?? const [];
  }

  /// PUT a partial update to one light resource, e.g.
  /// `{"on": {"on": true}}` or `{"dimming": {"brightness": 50.0}}`.
  Future<void> putLight(String lightId, Map<String, dynamic> body) async {
    final response = await _http
        .put(
          _uri('/clip/v2/resource/light/$lightId'),
          headers: {..._headers, 'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 8));
    _checkOk(response);
  }

  /// Recall (activate) a scene — CLIP v2 has no separate "run" endpoint;
  /// activation is a PUT that sets the scene's own `recall.action`.
  Future<void> recallScene(String sceneId) async {
    final response = await _http
        .put(
          _uri('/clip/v2/resource/scene/$sceneId'),
          headers: {..._headers, 'Content-Type': 'application/json'},
          body: jsonEncode({
            'recall': {'action': 'active'},
          }),
        )
        .timeout(const Duration(seconds: 8));
    _checkOk(response);
  }

  void _checkOk(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
          'Bridge returned ${response.statusCode}: ${response.body}');
    }
  }

  void close() => _http.close();

  /// Press-the-link-button pairing flow.
  ///
  /// POSTs a registration request to `/api`; the bridge only grants a key if
  /// its physical link button was pressed within the last ~30 seconds,
  /// which it reports back as error 101 — translated here into the
  /// instruction the user actually needs, rather than a raw error code.
  ///
  /// This is a one-shot, pre-authentication call, so it opens its own short-
  /// lived client rather than requiring an [HueClient] (which needs an
  /// application key this call is the one that produces).
  static Future<HuePairResult> pairWithBridge(String ip) async {
    final client = io_client.IOClient(
      HttpClient()..badCertificateCallback = (cert, host, port) => host == ip,
    );
    try {
      final response = await client
          .post(
            Uri.parse('https://$ip/api'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'devicetype': 'home_deck#panel'}),
          )
          .timeout(const Duration(seconds: 8));

      final body = jsonDecode(response.body);
      if (body is! List || body.isEmpty) {
        return (ok: false, applicationKey: null, message: 'Unexpected reply from bridge.');
      }
      final entry = body.first as Map<String, dynamic>;

      final error = entry['error'] as Map<String, dynamic>?;
      if (error != null) {
        if (error['type'] == 101) {
          return (
            ok: false,
            applicationKey: null,
            message: 'Press the link button on the bridge, then try again.'
          );
        }
        return (
          ok: false,
          applicationKey: null,
          message: error['description'] as String? ?? 'Pairing failed.'
        );
      }

      final success = entry['success'] as Map<String, dynamic>?;
      final key = success?['username'] as String?;
      if (key == null) {
        return (
          ok: false,
          applicationKey: null,
          message: 'Bridge did not return an application key.'
        );
      }
      return (ok: true, applicationKey: key, message: 'Paired.');
    } on TimeoutException {
      return (ok: false, applicationKey: null, message: 'No response — check the bridge IP.');
    } catch (e) {
      return (ok: false, applicationKey: null, message: 'Could not reach bridge: $e');
    } finally {
      client.close();
    }
  }
}
