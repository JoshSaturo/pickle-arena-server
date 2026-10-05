import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

String matchId() {
  final random = Random.secure();
  final bytes = List.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final s = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}-${s.substring(16, 20)}-${s.substring(20)}';
}

abstract class MatchRecords {
  Future<String?> identify(String accessToken);
  Future<void> save(
    String id,
    String host,
    String guest,
    int hostScore,
    int guestScore,
  );
}

/// The elevated key stays in the server environment, never in the APK.
class SupabaseRecords implements MatchRecords {
  SupabaseRecords(this.url, this.key) {
    if (url.scheme != 'https' ||
        url.host.isEmpty ||
        url.userInfo.isNotEmpty ||
        url.hasQuery ||
        url.hasFragment ||
        (url.path != '' && url.path != '/')) {
      throw ArgumentError('SUPABASE_URL must be an HTTPS project origin');
    }
  }
  final Uri url;
  final String key;
  static MatchRecords? fromEnvironment() {
    final url = Platform.environment['SUPABASE_URL'] ?? '';
    final key = Platform.environment['SUPABASE_SERVICE_ROLE_KEY'] ?? '';
    if (url.isEmpty && key.isEmpty) return null;
    if (url.isEmpty || key.isEmpty) {
      throw StateError('Set both SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY');
    }
    return SupabaseRecords(Uri.parse(url), key);
  }

  Future<dynamic> _request(
    String path, {
    String? token,
    Map<String, dynamic>? body,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    try {
      return await (() async {
        final request = await client.openUrl(
          body == null ? 'GET' : 'POST',
          url.resolve(path),
        );
        request.followRedirects = false;
        request.headers.set('apikey', key);
        // Legacy service-role JWTs work as Authorization; new secret keys only
        // belong in apikey. User identity always uses the user's bearer token.
        if (token != null || !key.startsWith('sb_secret_')) {
          request.headers.set('Authorization', 'Bearer ${token ?? key}');
        }
        if (body != null) {
          request.headers.contentType = ContentType.json;
          request.write(jsonEncode(body));
        }
        final response = await request.close();
        if (response.statusCode == 401 || response.statusCode == 403) {
          throw const HttpException('Account authorization failed');
        }
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw const HttpException('Database request failed');
        }
        final bytes = <int>[];
        await for (final chunk in response) {
          bytes.addAll(chunk);
          if (bytes.length > 65536) {
            throw const FormatException('Response too large');
          }
        }
        return bytes.isEmpty ? null : jsonDecode(utf8.decode(bytes));
      })().timeout(const Duration(seconds: 5));
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<String?> identify(String accessToken) async {
    final user = await _request('/auth/v1/user', token: accessToken);
    final id = user is Map ? user['id'] : null;
    return id is String && RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(id)
        ? id
        : null;
  }

  @override
  Future<void> save(
    String id,
    String host,
    String guest,
    int hostScore,
    int guestScore,
  ) async {
    await _request(
      '/rest/v1/rpc/record_online_match',
      body: {
        'p_id': id,
        'p_host': host,
        'p_guest': guest,
        'p_host_score': hostScore,
        'p_guest_score': guestScore,
      },
    );
  }
}
