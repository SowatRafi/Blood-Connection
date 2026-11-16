// Network access is centralized so every request carries the same identity and country boundary.
import 'dart:convert';
import 'dart:typed_data';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

/// A decoded API object; endpoint-specific fields are interpreted by the caller.
typedef Json = Map<String, dynamic>;
const demoEnabled = bool.fromEnvironment('DEMO_MODE');
const apiUrl = String.fromEnvironment(
  'API_URL',
  defaultValue: 'http://127.0.0.1:8000/api/v1',
);
const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
const supabaseKey = String.fromEnvironment('SUPABASE_ANON_KEY');
const hasAuth = supabaseUrl != '' && supabaseKey != '';
const bloodGroups = ['A+', 'A−', 'B+', 'B−', 'AB+', 'AB−', 'O+', 'O−'];
// One shared signature keeps the community identity consistent across every screen.
const attribution = 'An initiative by Bindubashini Boys’ 2015 & Friends';

/// Creates a submission key to retain across retries of the same form.
///
/// Generate a new key for a new submission, not for a lost acknowledgement.
String newSubmissionKey() {
  final random = Random.secure();
  return List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

/// Checks upload size and a JPEG/PNG signature before sending private images.
///
/// This is client preflight only; the server must verify and sanitize the pixels.
String privateImageType(Uint8List bytes) {
  if (bytes.length > 5 * 1024 * 1024) {
    throw const ApiException('Choose an image no larger than 5 MB.');
  }
  if (bytes.length > 2 && bytes[0] == 0xff && bytes[1] == 0xd8) {
    return 'image/jpeg';
  }
  if (bytes.length > 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4e &&
      bytes[3] == 0x47) {
    return 'image/png';
  }
  throw const ApiException('Choose a JPEG or PNG image.');
}

/// A displayable failure with an optional HTTP status for onboarding decisions.
class ApiException implements Exception {
  final String message;
  final int? statusCode;
  const ApiException(this.message, {this.statusCode});
  @override
  String toString() => message;
}

/// Session-scoped transport for JSON and private images in the active country.
///
/// Location changes update [country] after the server returns the routed profile.
/// The backend remains responsible for identity, role and country authorization.
class Api {
  final http.Client client;
  String country = demoEnabled ? 'BD' : '';
  bool demo = false;
  String demoIdentity = 'seeker';
  Api({http.Client? client}) : client = client ?? http.Client();

  // All JSON and private-image requests share token, country, TLS, error and timeout rules.
  Future<http.Response> _send(
    String path, {
    String method = 'GET',
    List<int>? bytes,
    String contentType = 'application/json',
    Map<String, String>? query,
  }) async {
    final token = demo && demoEnabled
        ? switch (demoIdentity) {
            'seeker' => 'demo-seeker',
            'donor' => 'demo-donor',
            'admin' => 'demo-admin',
            _ => throw const ApiException('Unknown local demo identity.'),
          }
        : (hasAuth
              ? Supabase.instance.client.auth.currentSession?.accessToken
              : null);
    final base = Uri.parse('$apiUrl$path');
    if (!(demo && demoEnabled) && base.scheme != 'https') {
      throw const ApiException(
        'A secure HTTPS server is required. Ask your administrator to configure it.',
      );
    }
    final request = http.Request(method, base.replace(queryParameters: query))
      ..headers.addAll({
        'Content-Type': contentType,
        'X-Country': country,
        if (token != null) 'Authorization': 'Bearer $token',
      });
    if (bytes != null) request.bodyBytes = bytes;
    try {
      final response = await client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(const Duration(seconds: 20));
      if (response.statusCode >= 400) {
        dynamic data;
        try {
          data = jsonDecode(response.body);
        } catch (_) {
          data = null;
        }
        final detail = data is Map ? data['detail'] : null;
        throw ApiException(
          detail is String
              ? detail
              : 'Please check your details and try again.',
          statusCode: response.statusCode,
        );
      }
      return response;
    } on ApiException {
      rethrow;
    } catch (_) {
      throw const ApiException(
        'Could not reach Blood Connection. Check your connection and try again.',
      );
    }
  }

  /// Sends a JSON object and normalizes empty responses to an empty object.
  ///
  /// Unexpected response shapes become the same displayable error as other
  /// transport failures, so screens do not expose decoding internals.
  Future<Json> request(
    String path, {
    String method = 'GET',
    Json? body,
    Map<String, String>? query,
  }) async {
    final response = await _send(
      path,
      method: method,
      bytes: body == null ? null : utf8.encode(jsonEncode(body)),
      query: query,
    );
    try {
      return response.body.isEmpty
          ? {}
          : Json.from(jsonDecode(response.body) as Map);
    } catch (_) {
      throw const ApiException(
        'The server returned an unexpected response. Please try again.',
      );
    }
  }

  /// Fetches private photo bytes through the server's access check on each call.
  Future<Uint8List> photo(String userId) async =>
      (await _send('/profiles/${Uri.encodeComponent(userId)}/photo')).bodyBytes;
  /// Replaces the signed-in member's photo after local file preflight.
  Future<Json> uploadPhoto(Uint8List bytes) async {
    final response = await _send(
      '/me/photo',
      method: 'PUT',
      bytes: bytes,
      contentType: privateImageType(bytes),
    );
    return Json.from(jsonDecode(response.body) as Map);
  }

  /// Uploads evidence within the report access boundary without a public URL.
  Future<Json> uploadReportEvidence(String reportId, Uint8List bytes) async {
    final response = await _send(
      '/reports/${Uri.encodeComponent(reportId)}/evidence',
      method: 'POST',
      bytes: bytes,
      contentType: privateImageType(bytes),
    );
    return Json.from(jsonDecode(response.body) as Map);
  }

  /// Reads a report's original country without changing the active location.
  Future<Uint8List> reportEvidence(
    String reportId,
    String evidenceId, {
    String? country,
  }) => _evidence('/reports', reportId, evidenceId, country: country);
  /// Uses the moderator endpoint, whose role check is enforced by the server.
  Future<Uint8List> adminReportEvidence(String reportId, String evidenceId) =>
      _evidence('/admin/reports', reportId, evidenceId);

  // Sanitized server images are bounded before a screen decodes them into a larger pixel buffer.
  Future<Uint8List> _evidence(
    String prefix,
    String reportId,
    String evidenceId, {
    String? country,
  }) async {
    final response = await _send(
      '$prefix/${Uri.encodeComponent(reportId)}/evidence/${Uri.encodeComponent(evidenceId)}',
      query: country == null ? null : {'country': country},
    );
    if (response.bodyBytes.length > 5 * 1024 * 1024) {
      throw const ApiException('This evidence image is too large to display.');
    }
    return response.bodyBytes;
  }

  /// Unwraps the API's list envelope into object maps for consuming screens.
  Future<List<Json>> list(String path, {Map<String, String>? query}) async =>
      ((await request(path, query: query))['items'] as List)
          .map((e) => Json.from(e as Map))
          .toList();
  /// Releases transport resources when this signed-in route ends.
  void close() => client.close();
}

/// Converts the display minus to the API's ASCII blood-group notation.
String wireBlood(String value) => value.replaceAll('−', '-');
/// Uses a typographic minus for the same blood-group value in the interface.
String displayBlood(Object? value) =>
    (value?.toString() ?? '').replaceAll('-', '−');
/// Extracts the supplied calendar date without converting it between time zones.
String shortDate(Object? value) =>
    value == null ? '' : value.toString().split('T').first;

/// Reads the server's pause deadline, including legacy dates at UTC midnight.
DateTime? donationPauseEnd(Json profile) {
  final precise = profile['eligible_after_utc'];
  if (precise != null) return DateTime.tryParse(precise.toString());
  final date = profile['eligible_after'];
  return date == null
      ? null
      : DateTime.tryParse('${shortDate(date)}T00:00:00Z');
}
