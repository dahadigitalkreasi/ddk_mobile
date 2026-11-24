import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:dio/dio.dart';

class ChatInboxReverbService {
  ChatInboxReverbService({
    required this.apiBaseUrl,
    required this.wsBaseUrl,
    required this.appKey,
    required this.authToken,
    required this.userId,
    Dio? dio,
  }) : assert(userId > 0),
       _dio = dio ?? Dio();

  final String apiBaseUrl;
  final String wsBaseUrl;
  final String appKey;
  final String authToken;
  final int userId;
  final Dio _dio;

  final StreamController<Map<String, dynamic>> _messages =
      StreamController<Map<String, dynamic>>.broadcast();

  final StreamController<String> _statuses =
      StreamController<String>.broadcast();

  Stream<Map<String, dynamic>> get messages => _messages.stream;
  Stream<String> get statuses => _statuses.stream;

  String get channelName => 'private-chat-inbox-user.$userId';

  WebSocket? _socket;
  StreamSubscription<dynamic>? _subscription;

  bool _disposed = false;
  bool _subscribed = false;
  int _generation = 0;

  bool get isSubscribed => _subscribed;

  String get _authUrl {
    final base = apiBaseUrl.replaceAll(RegExp(r'/+$'), '');

    final root = base.endsWith('/api')
        ? base.substring(0, base.length - 4)
        : base;

    return '$root/api/broadcasting/auth';
  }

  Uri get _webSocketUri {
    final base = Uri.tryParse(wsBaseUrl.trim());

    if (base == null ||
        (base.scheme != 'ws' && base.scheme != 'wss') ||
        base.host.isEmpty) {
      throw const FormatException(
        'REVERB_WS_URL tidak valid. Gunakan ws:// atau wss://',
      );
    }

    if (appKey.trim().isEmpty) {
      throw const FormatException('REVERB_APP_KEY belum dikonfigurasi.');
    }

    final path = base.path.replaceAll(RegExp(r'/+$'), '');

    return base.replace(
      path: '$path/app/${Uri.encodeComponent(appKey)}',
      queryParameters: {
        'protocol': '7',
        'client': 'flutter',
        'version': '1.0',
        'flash': 'false',
      },
    );
  }

  Future<void> connect() async {
    if (_disposed) {
      throw StateError('ChatInboxReverbService sudah ditutup.');
    }

    await disconnect();

    if (_disposed) return;

    final generation = ++_generation;

    _subscribed = false;
    _setStatus('menghubungkan');

    try {
      if (authToken.trim().isEmpty) {
        throw const FormatException('Token login tidak tersedia.');
      }

      final uri = _webSocketUri;

      developer.log(
        'Menghubungkan WebSocket: ${uri.scheme}://${uri.authority}',
        name: 'ChatInboxReverb',
      );

      final socket = await WebSocket.connect(uri.toString())
          .timeout(const Duration(seconds: 15));

      if (_disposed || generation != _generation) {
        await socket.close();
        return;
      }

      _socket = socket;

      _subscription = socket.listen(
        (dynamic raw) {
          _onFrame(raw, generation);
        },
        onError: (Object error, StackTrace stackTrace) {
          if (_disposed || generation != _generation) return;

          _subscribed = false;
          _socket = null;

          _logError('WebSocket stream error', error, stackTrace);

          _setStatus('error: $error');
        },
        onDone: () {
          if (_disposed || generation != _generation) return;

          _subscribed = false;
          _socket = null;

          _setStatus('terputus');
        },
        cancelOnError: false,
      );

      // Aktifkan ping setelah listener terpasang.
      socket.pingInterval = const Duration(seconds: 25);
    } catch (error, stackTrace) {
      _logError('WebSocket connection error', error, stackTrace);

      if (!_disposed && generation == _generation) {
        _subscribed = false;
        _setStatus('gagal terhubung: $error');
      }

      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> _onFrame(dynamic raw, int generation) async {
    if (_disposed || generation != _generation || raw is! String) {
      return;
    }

    try {
      final decoded = jsonDecode(raw);

      if (decoded is! Map) return;

      final frame = Map<String, dynamic>.from(decoded);

      final eventName = frame['event']?.toString() ?? '';
      final channel = frame['channel']?.toString() ?? '';
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
          if (channel == channelName) {
            _subscribed = true;
            _setStatus('terhubung');

            developer.log(
              'Berhasil subscribe: $channelName',
              name: 'ChatInboxReverb',
            );
          }
          break;

        case 'pusher:ping':
          _send({'event': 'pusher:pong', 'data': {}});
          break;

        case 'pusher:error':
        case 'pusher_internal:subscription_error':
          _subscribed = false;

          developer.log(
            'Subscription error: ${frame['data']}',
            name: 'ChatInboxReverb',
          );

          _setStatus('error: ${frame['data']}');
          break;

        case 'chat.inbox.berubah':
          if (channel == channelName && _subscribed && !_messages.isClosed) {
            _messages.add(data);
          }
          break;

        default:
          // Abaikan event yang tidak digunakan.
          break;
      }
    } catch (error, stackTrace) {
      _logError('WebSocket frame processing error', error, stackTrace);

      if (!_disposed && generation == _generation) {
        _setStatus('error pemrosesan WebSocket: $error');
      }
    }
  }

  Future<void> _authorizeAndSubscribe(String socketId, int generation) async {
    try {
      final response = await _dio.post<dynamic>(
        _authUrl,
        data: {'socket_id': socketId, 'channel_name': channelName},
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          headers: {
            'Accept': 'application/json',
            'Authorization': 'Bearer $authToken',
          },
          sendTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 15),
        ),
      );

      if (_disposed || generation != _generation) return;

      final body = response.data;

      final authorization = body is Map ? body['auth']?.toString() : null;

      if (authorization == null || authorization.isEmpty) {
        throw const FormatException(
          'Respons broadcasting/auth tidak memiliki field auth.',
        );
      }

      final socket = _socket;

      if (socket == null || socket.readyState != WebSocket.open) {
        throw StateError('WebSocket terputus sebelum subscribe.');
      }

      _send({
        'event': 'pusher:subscribe',
        'data': {'auth': authorization, 'channel': channelName},
      });
    } on DioException catch (error, stackTrace) {
      _logError('Broadcasting authorization error', error, stackTrace);

      if (!_disposed && generation == _generation) {
        final statusCode = error.response?.statusCode;

        _setStatus('gagal otorisasi: HTTP ${statusCode ?? '-'}');
      }
    } catch (error, stackTrace) {
      _logError('Broadcasting subscription error', error, stackTrace);

      if (!_disposed && generation == _generation) {
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
      // Payload bukan JSON.
    }

    return <String, dynamic>{};
  }

  void _send(Map<String, dynamic> frame) {
    final socket = _socket;

    if (_disposed || socket == null || socket.readyState != WebSocket.open) {
      return;
    }

    try {
      socket.add(jsonEncode(frame));
    } catch (error, stackTrace) {
      _logError('WebSocket send error', error, stackTrace);

      _setStatus('error mengirim WebSocket: $error');
    }
  }

  void _setStatus(String value) {
    if (!_disposed && !_statuses.isClosed) {
      _statuses.add(value);
    }
  }

  void _logError(String message, Object error, StackTrace stackTrace) {
    developer.log(
      message,
      name: 'ChatInboxReverb',
      error: error,
      stackTrace: stackTrace,
    );
  }

  Future<void> disconnect() async {
    ++_generation;
    _subscribed = false;

    final subscription = _subscription;
    _subscription = null;

    if (subscription != null) {
      await subscription.cancel();
    }

    final socket = _socket;
    _socket = null;

    if (socket != null) {
      try {
        await socket.close().timeout(const Duration(seconds: 3));
      } catch (error, stackTrace) {
        _logError('WebSocket disconnect error', error, stackTrace);
      }
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;

    _disposed = true;

    await disconnect();

    await _messages.close();
    await _statuses.close();
  }
}
