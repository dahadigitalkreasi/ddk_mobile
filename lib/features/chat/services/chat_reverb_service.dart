import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

/// Koneksi real-time Laravel Reverb untuk satu chat Packing <-> CS.
///
/// Gunakan wsBaseUrl contoh 'ws://192.168.1.10:8080' (Android fisik)
/// atau 'wss://ws.domain-anda.com' (produksi dengan TLS).
/// apiBaseUrl contoh 'http://192.168.1.10' atau 'https://domain-anda.com'.
/// appKey = REVERB_APP_KEY (bukan APP_KEY atau REVERB_APP_SECRET).
/// authToken = token Sanctum user yang sedang login (tanpa prefix Bearer).
class ChatReverbService {
  ChatReverbService({
    required this.apiBaseUrl,
    required this.wsBaseUrl,
    required this.appKey,
    required this.authToken,
    required this.chatId,
    Dio? dio,
  }) : assert(chatId > 0),
       _dio = dio ?? Dio();

  final String apiBaseUrl;
  final String wsBaseUrl;
  final String appKey;
  final String authToken;
  final int chatId;
  final Dio _dio;

  final StreamController<Map<String, dynamic>> _messages =
      StreamController<Map<String, dynamic>>.broadcast();
  final StreamController<String> _statuses =
      StreamController<String>.broadcast();
  final StreamController<Map<String, dynamic>> _readReceipts =
      StreamController<Map<String, dynamic>>.broadcast();

  Stream<Map<String, dynamic>> get messages => _messages.stream;
  Stream<String> get statuses => _statuses.stream;
  Stream<Map<String, dynamic>> get readReceipts => _readReceipts.stream;

  String get channelName => 'private-packing-chat.$chatId';

  WebSocket? _socket;
  StreamSubscription<dynamic>? _subscription;
  bool _disposed = false;
  bool _subscribed = false;
  int _generation = 0;

  bool get isSubscribed => _subscribed;

  Future<void> connect() async {
    if (_disposed) {
      throw StateError('ChatReverbService sudah ditutup.');
    }

    await disconnect();
    final generation = ++_generation;
    _setStatus('menghubungkan');

    final base = Uri.parse(wsBaseUrl);
    if (base.scheme != 'ws' && base.scheme != 'wss') {
      throw ArgumentError('wsBaseUrl wajib diawali ws:// atau wss://');
    }

    final uri = base.replace(
      path:
          '${base.path.replaceAll(RegExp(r'/$'), '')}/app/${Uri.encodeComponent(appKey)}',
      queryParameters: {
        'protocol': '7',
        'client': 'flutter',
        'version': '1.0',
        'flash': 'false',
      },
    );

    try {
      final socket = await WebSocket.connect(uri.toString());
      if (_disposed || generation != _generation) {
        await socket.close();
        return;
      }
      _socket = socket;
      socket.pingInterval = const Duration(seconds: 25);
      _subscription = socket.listen(
        (raw) => _onFrame(raw, generation),
        onError: (Object error) {
          if (generation == _generation) {
            _subscribed = false;
            _setStatus('error: $error');
          }
        },
        onDone: () {
          if (generation == _generation) {
            _subscribed = false;
            _socket = null;
            _setStatus('terputus');
          }
        },
        cancelOnError: false,
      );
    } catch (error) {
      if (generation == _generation) {
        _setStatus('gagal terhubung: $error');
      }
      rethrow;
    }
  }

  Future<void> _onFrame(dynamic raw, int generation) async {
    if (_disposed || generation != _generation || raw is! String) return;

    try {
      final frame = jsonDecode(raw);
      if (frame is! Map) return;
      final eventName = frame['event']?.toString() ?? '';
      final data = _decodeData(frame['data']);

      switch (eventName) {
        case 'pusher:connection_established':
          final socketId = data['socket_id']?.toString();
          if (socketId == null || socketId.isEmpty) {
            _setStatus('error: socket_id kosong');
            return;
          }
          _setStatus('mengotorisasi');
          await _authorizeAndSubscribe(socketId, generation);
          break;
        case 'pusher_internal:subscription_succeeded':
          if (frame['channel']?.toString() == channelName) {
            _subscribed = true;
            _setStatus('terhubung');
          }
          break;
        case 'pusher:ping':
          _send({'event': 'pusher:pong', 'data': {}});
          break;
        case 'pusher:error':
        case 'pusher_internal:subscription_error':
          _setStatus('error: ${frame['data']}');
          break;
        case 'chat.pesan.dibaca':
          if (frame['channel']?.toString() == channelName &&
              !_readReceipts.isClosed) {
            _readReceipts.add(data);
          }
          break;
        case 'chat.pesan.baru':
          if (frame['channel']?.toString() == channelName &&
              !_messages.isClosed) {
            _messages.add(data);
          }
          break;
      }
    } catch (error) {
      _setStatus('error pemrosesan WebSocket: $error');
    }
  }

  Future<void> _authorizeAndSubscribe(String socketId, int generation) async {
    try {
      final response = await _dio.post<dynamic>(
        '${apiBaseUrl.replaceAll(RegExp(r'/$'), '')}/api/broadcasting/auth',
        data: {'socket_id': socketId, 'channel_name': channelName},
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          headers: {
            'Accept': 'application/json',
            'Authorization': 'Bearer $authToken',
          },
        ),
      );

      if (_disposed || generation != _generation) return;

      final body = response.data;
      final authorization = body is Map ? body['auth']?.toString() : null;
      if (authorization == null || authorization.isEmpty) {
        throw const FormatException('Respons auth tidak memiliki field auth.');
      }
      _send({
        'event': 'pusher:subscribe',
        'data': {'auth': authorization, 'channel': channelName},
      });
    } catch (error) {
      if (generation == _generation) {
        _setStatus('gagal otorisasi: $error');
      }
    }
  }

  static Map<String, dynamic> _decodeData(dynamic value) {
    try {
      final decoded = value is String ? jsonDecode(value) : value;
      if (decoded is Map) {
        return decoded.map((key, val) => MapEntry(key.toString(), val));
      }
    } catch (_) {
      // Abaikan payload non-JSON.
    }
    return <String, dynamic>{};
  }

  void _send(Map<String, dynamic> frame) {
    final socket = _socket;
    if (socket != null && socket.readyState == WebSocket.open) {
      socket.add(jsonEncode(frame));
    }
  }

  void _setStatus(String value) {
    if (!_disposed && !_statuses.isClosed) _statuses.add(value);
  }

  Future<void> disconnect() async {
    ++_generation;
    _subscribed = false;
    final subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
    final socket = _socket;
    _socket = null;
    if (socket != null) await socket.close();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    await disconnect();
    _disposed = true;
    await _messages.close();
    await _readReceipts.close();
    await _statuses.close();
  }
}
