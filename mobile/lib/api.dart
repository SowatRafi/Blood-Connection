// Network access is centralized so every request carries the same identity and country boundary.
import 'dart:convert';
import 'dart:typed_data';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

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

// Retain one key per form so retrying a lost acknowledgement cannot duplicate a submitted record.
String newSubmissionKey() {
  final random = Random.secure();
  return List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

// Shared local checks reject unsuitable images before upload; the server verifies and sanitizes pixels.
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

// One readable failure type keeps server validation visible without leaking HTTP internals.
class ApiException implements Exception {
  final String message;
  final int? statusCode;
  const ApiException(this.message, {this.statusCode});
  @override
  String toString() => message;
}

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

  // Private photos are authenticated bytes, never reusable public URLs or files on shared storage.
  Future<Uint8List> photo(String userId) async =>
      (await _send('/profiles/${Uri.encodeComponent(userId)}/photo')).bodyBytes;
  Future<Json> uploadPhoto(Uint8List bytes) async {
    final response = await _send(
      '/me/photo',
      method: 'PUT',
      bytes: bytes,
      contentType: privateImageType(bytes),
    );
    return Json.from(jsonDecode(response.body) as Map);
  }

  // Report evidence uses the same identity/country boundary and never exposes reusable public URLs.
  Future<Json> uploadReportEvidence(String reportId, Uint8List bytes) async {
    final response = await _send(
      '/reports/${Uri.encodeComponent(reportId)}/evidence',
      method: 'POST',
      bytes: bytes,
      contentType: privateImageType(bytes),
    );
    return Json.from(jsonDecode(response.body) as Map);
  }

  Future<Uint8List> reportEvidence(
    String reportId,
    String evidenceId, {
    String? country,
  }) => _evidence('/reports', reportId, evidenceId, country: country);
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

  // Typed list conversion avoids spreading unchecked JSON casts across screens.
  Future<List<Json>> list(String path, {Map<String, String>? query}) async =>
      ((await request(path, query: query))['items'] as List)
          .map((e) => Json.from(e as Map))
          .toList();
  void close() => client.close();
}

// The API uses ASCII minus while typography uses a true minus for clearer blood groups.
String wireBlood(String value) => value.replaceAll('−', '-');
String displayBlood(Object? value) =>
    (value?.toString() ?? '').replaceAll('-', '−');
String shortDate(Object? value) =>
    value == null ? '' : value.toString().split('T').first;

// Use the server's absolute pause boundary; older date-only records were defined at UTC midnight.
DateTime? donationPauseEnd(Json profile) {
  final precise = profile['eligible_after_utc'];
  if (precise != null) return DateTime.tryParse(precise.toString());
  final date = profile['eligible_after'];
  return date == null
      ? null
      : DateTime.tryParse('${shortDate(date)}T00:00:00Z');
}
