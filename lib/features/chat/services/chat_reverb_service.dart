import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

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

  final _messages = StreamController<Map<String, dynamic>>.broadcast();

  final _statuses = StreamController<String>.broadcast();

  final _readReceipts = StreamController<Map<String, dynamic>>.broadcast();

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

  String get _authRoot {
    final base = apiBaseUrl.trim().replaceAll(RegExp(r'/+$'), '');

    return base.endsWith('/api') ? base.substring(0, base.length - 4) : base;
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
      throw const FormatException('REVERB_APP_KEY tidak tersedia.');
    }

    final basePath = base.path.replaceAll(RegExp(r'/+$'), '');

    return base.replace(
      path: '$basePath/app/${Uri.encodeComponent(appKey)}',
      queryParameters: {
        'protocol': '7',
        'client': 'flutter',
        'version': '1.0',
        'flash': 'false',
      },
    );
  }

  void _log(
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    debugPrint('[ChatReverb] $message');

    if (error != null) {
      debugPrint('[ChatReverb] ERROR: $error');
      debugPrint('[ChatReverb] ERROR TYPE: ${error.runtimeType}');
    }

    if (stackTrace != null && kDebugMode) {
      debugPrintStack(
        label: '[ChatReverb] STACK TRACE',
        stackTrace: stackTrace,
      );
    }
  }

  void _setStatus(String value) {
    if (_disposed || _statuses.isClosed) return;

    _log('Status: $value');
    _statuses.add(value);
  }

  Future<void> connect() async {
    if (_disposed) {
      throw StateError('ChatReverbService sudah ditutup.');
    }

    await disconnect();

    if (_disposed) return;

    final generation = ++_generation;
    _subscribed = false;

    String stage = 'validasi konfigurasi';

    _setStatus('menghubungkan');

    try {
      if (authToken.trim().isEmpty) {
        throw const FormatException('Token login tidak tersedia.');
      }

      final uri = _webSocketUri;

      _log('Target: ${uri.scheme}://${uri.authority}');

      stage = 'WebSocket.connect';

      _log('Mulai membuka WebSocket');

      final socket = await WebSocket.connect(uri.toString())
          .timeout(const Duration(seconds: 15));

      _log('WebSocket berhasil dibuka');

      if (_disposed || generation != _generation) {
        await socket.close();
        return;
      }

      stage = 'memasang listener';

      _socket = socket;

      _subscription = socket.listen(
        (dynamic raw) {
          _onFrame(raw, generation);
        },
        onError: (Object error, StackTrace stackTrace) {
          if (_disposed || generation != _generation) {
            return;
          }

          _subscribed = false;

          _log('WebSocket stream error', error: error, stackTrace: stackTrace);

          _setStatus('error: $error');
        },
        onDone: () {
          if (_disposed || generation != _generation) {
            return;
          }

          _subscribed = false;
          _socket = null;

          _log('WebSocket terputus');
          _setStatus('terputus');
        },
        cancelOnError: false,
      );

      stage = 'mengatur pingInterval';

      socket.pingInterval = const Duration(seconds: 25);

      _log('Listener dan ping berhasil dipasang');
    } catch (error, stackTrace) {
      _log(
        'Koneksi gagal pada tahap: $stage',
        error: error,
        stackTrace: stackTrace,
      );

      if (!_disposed && generation == _generation) {
        _subscribed = false;

        _setStatus('gagal terhubung ($stage): $error');
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

      final frame = decoded.map(
        (key, value) => MapEntry(key.toString(), value),
      );

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

          _log('Socket ID diterima');
          _setStatus('mengotorisasi');

          await _authorizeAndSubscribe(socketId, generation);
          break;

        case 'pusher_internal:subscription_succeeded':
          if (channel == channelName) {
            _subscribed = true;

            _log('Private channel berhasil subscribe');

            _setStatus('terhubung');
          }
          break;

        case 'pusher:ping':
          _send({'event': 'pusher:pong', 'data': {}});
          break;

        case 'pusher:error':
        case 'pusher_internal:subscription_error':
          _subscribed = false;

          _log('Server menolak event/subscription');

          _setStatus('error: ${frame['data']}');
          break;

        case 'chat.pesan.baru':
          if (channel == channelName && !_messages.isClosed) {
            _log('Event pesan baru diterima');
            _messages.add(data);
          }
          break;

        case 'chat.pesan.dibaca':
          if (channel == channelName && !_readReceipts.isClosed) {
            _log('Event pesan dibaca diterima');
            _readReceipts.add(data);
          }
          break;

        default:
          // Event lain tidak perlu diproses.
          break;
      }
    } catch (error, stackTrace) {
      _log(
        'Gagal memproses frame WebSocket',
        error: error,
        stackTrace: stackTrace,
      );

      if (!_disposed && generation == _generation) {
        _setStatus('error pemrosesan WebSocket: $error');
      }
    }
  }

  Future<void> _authorizeAndSubscribe(String socketId, int generation) async {
    try {
      final response = await _dio.post<dynamic>(
        '$_authRoot/api/broadcasting/auth',
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

      if (_disposed || generation != _generation) {
        return;
      }

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

      _log('Otorisasi berhasil, mengirim subscribe');

      _send({
        'event': 'pusher:subscribe',
        'data': {'auth': authorization, 'channel': channelName},
      });
    } on DioException catch (error, stackTrace) {
      if (_disposed || generation != _generation) return;

      final statusCode = error.response?.statusCode;

      _log(
        'HTTP broadcasting/auth gagal: ${statusCode ?? '-'}',
        error: error,
        stackTrace: stackTrace,
      );

      _setStatus('gagal otorisasi: HTTP ${statusCode ?? '-'}');
    } catch (error, stackTrace) {
      if (_disposed || generation != _generation) return;

      _log('Autentikasi channel gagal', error: error, stackTrace: stackTrace);

      _setStatus('gagal otorisasi: $error');
    }
  }

  static Map<String, dynamic> _decodeData(dynamic value) {
    try {
      final decoded = value is String ? jsonDecode(value) : value;

      if (decoded is Map) {
        return decoded.map((key, val) => MapEntry(key.toString(), val));
      }
    } catch (_) {
      // Payload tidak valid atau bukan JSON.
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
      _log(
        'Gagal mengirim frame WebSocket',
        error: error,
        stackTrace: stackTrace,
      );

      _setStatus('error mengirim WebSocket: $error');
    }
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
        _log('Gagal menutup WebSocket', error: error, stackTrace: stackTrace);
      }
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;

    _disposed = true;

    await disconnect();

    await _messages.close();
    await _readReceipts.close();
    await _statuses.close();
  }
}
