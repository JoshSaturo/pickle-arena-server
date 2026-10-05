import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'records.dart';

/// Private two-player relay. Physics remains on the room creator's phone.
/// Accounts and durable records are optional; guest clients remain compatible.
class ArenaRelay {
  ArenaRelay({
    this.maxRooms = 100,
    this.waitingLifetime = const Duration(minutes: 15),
    this.matchLifetime = const Duration(hours: 2),
    this.idleTimeout = const Duration(seconds: 12),
    this.records,
  });
  final int maxRooms;
  final MatchRecords? records;
  final _writes = <Future<void>>{};
  final Duration waitingLifetime, matchLifetime, idleTimeout;
  final _rooms = <String, _Room>{};
  final _clients = <_Client>{};
  final _attempts = <String, ({DateTime since, int count})>{};
  final _random = Random.secure();
  HttpServer? _server;
  Timer? _sweeper;
  int _upgrading = 0;
  int get port => _server!.port;
  int get roomCount => _rooms.length;

  Future<void> start({int port = 8080, String address = '0.0.0.0'}) async {
    _server = await HttpServer.bind(address, port);
    _server!.listen(
      (request) => unawaited(
        _request(request).catchError((Object _) {
          // A client can disappear while an HTTP response/upgrade is being written.
          request.response.close().ignore();
        }),
      ),
    );
    _sweeper = Timer.periodic(const Duration(seconds: 1), (_) => _sweep());
  }

  Future<void> _request(HttpRequest request) async {
    if (request.method == 'GET' && request.uri.path == '/health') {
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'status': 'ok', 'protocol': 1}));
      await request.response.close();
      return;
    }
    if (request.uri.path != '/play' ||
        !WebSocketTransformer.isUpgradeRequest(request)) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    final ip = request.connectionInfo?.remoteAddress.address ?? 'unknown';
    final now = DateTime.now();
    var bucket = _attempts[ip];
    if (bucket == null || now.difference(bucket.since).inSeconds >= 60) {
      bucket = (since: now, count: 0);
    }
    if (_attempts.containsKey(ip) || _attempts.length < 4096) {
      _attempts[ip] = (since: bucket.since, count: bucket.count + 1);
    } else {
      request.response.statusCode = HttpStatus.serviceUnavailable;
      await request.response.close();
      return;
    }
    if (bucket.count >= 60 ||
        _clients.length + _upgrading >= maxRooms * 2 + 8) {
      request.response.statusCode = HttpStatus.serviceUnavailable;
      await request.response.close();
      return;
    }
    _upgrading++;
    try {
      final socket = await WebSocketTransformer.upgrade(
        request,
        compression: CompressionOptions.compressionOff,
      );
      if (_server == null) {
        await socket.close();
        return;
      }
      socket.pingInterval = const Duration(seconds: 5);
      final client = _Client(socket);
      _clients.add(client);
      socket.listen(
        (dynamic raw) => _message(client, raw),
        onDone: () => _disconnect(client),
        onError: (Object _) => _disconnect(client),
      );
    } catch (_) {
      // Failed upgrades must not take down rooms already in progress.
      request.response.close().ignore();
    } finally {
      _upgrading--;
    }
  }

  void _message(_Client client, dynamic raw) {
    if (client.closed) return;
    try {
      final now = DateTime.now();
      if (now.difference(client.window).inSeconds >= 1) {
        client.window = now;
        client.messages = 0;
        client.bytes = 0;
      }
      if (raw is! String || raw.length > 16384) throw const FormatException();
      client.bytes += raw.length;
      if (++client.messages > 120 || client.bytes > 262144) {
        _reject(client, 'rate');
        return;
      }
      final m = jsonDecode(raw);
      if (m is! Map<String, dynamic>) throw const FormatException();
      client.lastSeen = now;
      final type = m['type'];
      if (type == 'ping') {
        client.send({'type': 'pong'});
        return;
      }
      if (type == 'leave') {
        _disconnect(client);
        return;
      }
      if (client.authenticating) return;
      final room = client.room;
      if (room == null) {
        if (m['protocol'] != 1) {
          _reject(client, 'version');
          return;
        }
        if (m.containsKey('access_token')) {
          final token = m['access_token'];
          if (token is! String || token.isEmpty || token.length > 8192 ||
              (type != 'create' && type != 'join')) {
            throw const FormatException();
          }
          if (records == null) { _reject(client, 'accounts_unavailable'); return; }
          client.authenticating = true;
          unawaited(_authenticate(client, m, token));
          return;
        }
        if (type == 'create') {
          if (_rooms.length >= maxRooms) {
            _reject(client, 'capacity');
            return;
          }
          String code;
          const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
          do {
            code = List.generate(
              8,
              (_) => alphabet[_random.nextInt(alphabet.length)],
            ).join();
          } while (_rooms.containsKey(code));
          final created = _Room(code, client);
          _rooms[code] = created;
          client.room = created;
          client.send({'type': 'room', 'role': 'host', 'code': code});
        } else if (type == 'join') {
          final found = _rooms[m['code']];
          if (found == null) {
            _reject(client, 'not_found');
            return;
          }
          if (found.guest != null) {
            _reject(client, 'full');
            return;
          }
          if (client.userId != null && client.userId == found.host.userId) {
            _reject(client, 'same_account');
            return;
          }
          found.guest = client;
          found.pairedAt = now;
          client.room = found;
          client.send({'type': 'room', 'role': 'guest', 'code': found.code});
          final tracked = found.host.userId != null && client.userId != null;
          found.host.send({'type': 'paired', 'tracked': tracked});
          client.send({'type': 'paired', 'tracked': tracked});
        } else {
          throw const FormatException();
        }
        return;
      }
      final host = room.host == client;
      final other = host ? room.guest : room.host;
      if (other == null) throw const FormatException();
      if (type == 'hello' && !host && !room.hello) {
        if (m['code'] != room.code || m['protocol'] != 1) {
          throw const FormatException();
        }
        room.hello = true;
        other.send(m);
        return;
      }
      if (type == 'welcome' && host && room.hello && !room.started) {
        if (m['protocol'] != 1) throw const FormatException();
        room.started = true;
        other.send(m);
        return;
      }
      if (!room.started) throw const FormatException();
      if (host) {
        switch (type) {
          case 'state':
            final sequence = m['sequence'];
            if (sequence is! int ||
                sequence <= room.lastSequence ||
                m['state'] is! Map ||
                room.pending.length >= 4) {
              throw const FormatException();
            }
            room.lastSequence = sequence;
            room.pending.add(sequence);
            _observeResult(room, m['state'] as Map, sequence);
          case 'sound':
            if (m['sound'] is! int ||
                (m['sound'] as int) < 0 ||
                (m['sound'] as int) > 8) {
              throw const FormatException();
            }
          case 'ready':
            if (m['host'] is! bool || m['guest'] is! bool) {
              throw const FormatException();
            }
          default:
            throw const FormatException();
        }
      } else {
        switch (type) {
          case 'input':
            for (final value in [m['x'], m['y']]) {
              if (value is! num || !value.isFinite || value.abs() > 1) {
                throw const FormatException();
              }
            }
          case 'shot':
            if (m['shot'] is! int ||
                (m['shot'] as int) < 0 ||
                (m['shot'] as int) > 3) {
              throw const FormatException();
            }
          case 'ack':
            final sequence = m['sequence'];
            if (sequence is! int || !room.pending.contains(sequence)) return;
            room.pending.removeWhere((s) => s <= sequence);
            final result = room.result;
            if (result != null && sequence >= result.sequence && !room.submitted) {
              room.submitted = true;
              final write = _saveResult(room, result);
              _writes.add(write);
              unawaited(write.whenComplete(() => _writes.remove(write)));
            }
          case 'pause':
          case 'active':
            if (m['value'] is! bool) throw const FormatException();
          case 'ready':
            break;
          default:
            throw const FormatException();
        }
      }
      other.send(m);
    } catch (_) {
      _reject(client, 'invalid');
    }
  }

  Future<void> _authenticate(_Client client, Map<String, dynamic> message, String token) async {
    try {
      final id = await records!.identify(token);
      if (client.closed || !_clients.contains(client)) return;
      if (id == null) { _reject(client, 'auth'); return; }
      client.userId = id;
      client.authenticating = false;
      // Never relay or retain the credential after checking it with Auth.
      _message(client, jsonEncode({...message}..remove('access_token')));
    } catch (_) {
      if (!client.closed) _reject(client, 'auth');
    }
  }

  void _observeResult(_Room room, Map state, int sequence) {
    if (records == null || room.host.userId == null || room.guest?.userId == null) return;
    final scores = state['scores'];
    if (scores is! List || scores.length != 2 ||
        scores.any((s) => s is! int || s < 0 || s > 999)) {
      return;
    }
    final a = scores[0] as int, b = scores[1] as int;
    if (state['over'] == false && a == 0 && b == 0 && room.submitted) {
      room.result = null;
      room.submitted = false;
      room.matchKey = matchId();
    }
    if (state['over'] == true && room.result == null &&
        max(a, b) >= 11 && (a - b).abs() >= 2) {
      room.result = (id: room.matchKey, sequence: sequence, hostScore: a, guestScore: b);
    }
  }

  Future<void> _saveResult(_Room room, ({String id, int sequence, int hostScore, int guestScore}) result) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        await records!.save(result.id, room.host.userId!, room.guest!.userId!, result.hostScore, result.guestScore);
        for (final member in [room.host, room.guest]) {
          member?.send({'type': 'record', 'saved': true});
        }
        return;
      } catch (_) {
        if (attempt < 2) await Future<void>.delayed(Duration(seconds: attempt + 1));
      }
    }
    for (final member in [room.host, room.guest]) {
      member?.send({'type': 'record', 'saved': false});
    }
  }

  void _reject(_Client client, String reason) {
    client.send({'type': 'relay_error', 'reason': reason});
    _disconnect(client);
  }

  void _disconnect(_Client client, {String reason = 'left'}) {
    if (!_clients.contains(client)) return;
    final room = client.room;
    if (room != null) {
      _rooms.remove(room.code);
      for (final member in [room.host, room.guest]) {
        if (member == null) continue;
        if (member != client) {
          member.send({'type': 'room_closed', 'reason': reason});
        }
        member.room = null;
        member.close();
        _clients.remove(member);
      }
    } else {
      client.close();
      _clients.remove(client);
    }
  }

  void _sweep() {
    final now = DateTime.now();
    _attempts.removeWhere(
      (_, bucket) => now.difference(bucket.since).inSeconds >= 60,
    );
    for (final client in _clients.toList()) {
      if (now.difference(client.lastSeen) > idleTimeout ||
          (client.room == null &&
              now.difference(client.created).inSeconds > 8)) {
        _disconnect(client);
      }
    }
    for (final room in _rooms.values.toList()) {
      if (now.difference(room.pairedAt ?? room.created) >
          (room.pairedAt == null ? waitingLifetime : matchLifetime)) {
        room.host.send({'type': 'room_closed', 'reason': 'expired'});
        _disconnect(room.host, reason: 'expired');
      }
    }
  }

  Future<void> close() async {
    _sweeper?.cancel();
    final server = _server;
    _server = null;
    for (final client in _clients.toList()) {
      _disconnect(client, reason: 'shutdown');
    }
    await server?.close(force: true);
    await Future.wait(_writes.toList());
  }
}

class _Room {
  _Room(this.code, this.host);
  final String code;
  final _Client host;
  _Client? guest;
  final created = DateTime.now();
  DateTime? pairedAt;
  bool hello = false, started = false;
  int lastSequence = 0;
  final pending = <int>[];
  String matchKey = matchId();
  bool submitted = false;
  ({String id, int sequence, int hostScore, int guestScore})? result;
}

class _Client {
  _Client(this.socket);
  final WebSocket socket;
  _Room? room;
  bool closed = false;
  bool authenticating = false;
  String? userId;
  final created = DateTime.now();
  DateTime lastSeen = DateTime.now(), window = DateTime.now();
  int messages = 0, bytes = 0;
  void send(Map<String, dynamic> message) {
    if (!closed && socket.readyState == WebSocket.open) {
      try {
        socket.add(jsonEncode(message));
      } catch (_) {
        close();
      }
    }
  }

  void close() {
    if (closed) return;
    closed = true;
    socket.close().ignore();
  }
}
