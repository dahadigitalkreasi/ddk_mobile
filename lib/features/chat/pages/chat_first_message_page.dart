import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../core/network/api_client.dart';
import 'chat_detail_page.dart';

/// Ruang Chat Meta untuk pesanan yang belum memiliki percakapan.
/// Pesan pertama dikirim saat tombol Kirim ditekan.
class ChatFirstMessagePage extends StatefulWidget {
  const ChatFirstMessagePage({
    super.key,
    required this.initialNoPesanan,
    this.initialIdPerProduk,
  });

  final String initialNoPesanan;
  final int? initialIdPerProduk;

  @override
  State<ChatFirstMessagePage> createState() => _ChatFirstMessagePageState();
}

class _ChatFirstMessagePageState extends State<ChatFirstMessagePage> {
  static const _storage = FlutterSecureStorage();
  final _message = TextEditingController();
  bool _sending = false;
  String? _error;

  // ID tetap selama pesan ini dicoba lagi, sehingga endpoint /pesan
  // dapat mengenali retry dan menghindari pesan ganda.
  String? _draftMessageId;
  String? _draftContent;

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  static Map<String, dynamic> _map(Object? value) =>
      value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

  static String _errorText(Object error) {
    if (error is DioException) {
      final body = _map(error.response?.data);
      return body['message']?.toString() ??
          'Request gagal (HTTP ${error.response?.statusCode ?? '-'}).';
    }
    return error.toString()
        .replaceFirst('Bad state: ', '')
        .replaceFirst('FormatException: ', '');
  }

  static String _newUuid() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // UUID v4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // RFC variant
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
  }

  Future<int?> _findChatId(Options options) async {
    final response = await ApiClient.dio.get<dynamic>(
      '/chat-klarifikasi-packing/pesanan/'
      '${Uri.encodeComponent(widget.initialNoPesanan)}',
      options: options,
    );
    final body = _map(response.data);
    if (body['success'] != true || body['exists'] is! bool) {
      throw const FormatException('Format pencarian chat tidak sesuai.');
    }
    if (body['exists'] != true) return null;
    final id = int.tryParse('${_map(body['data'])['id']}');
    if (id == null || id <= 0) {
      throw const FormatException('ID chat tidak ditemukan.');
    }
    return id;
  }

  void _openDetail(int chatId, {bool recovered = false}) {
    if (!mounted) return;
    if (recovered) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Koneksi sempat terputus. Periksa pesan terakhir di chat '
            'sebelum mengirim ulang.',
          ),
          duration: Duration(seconds: 5),
        ),
      );
    }
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => ChatDetailPage(chatId: chatId),
      ),
    );
  }

  Future<void> _sendFirstMessage() async {
    final isi = _message.text.trim();
    if (_sending || isi.isEmpty) return;

    if (_draftContent != isi) {
      _draftContent = isi;
      _draftMessageId = _newUuid();
    }

    setState(() {
      _sending = true;
      _error = null;
    });

    Options? options;
    try {
      final token = await _storage.read(key: 'auth_token');
      if (token == null || token.isEmpty) {
        throw StateError('Sesi login tidak ditemukan. Silakan login kembali.');
      }
      options = Options(headers: {
        'Authorization': 'Bearer $token',
        'Accept': 'application/json',
      });

      // API /chat membuat chat sekaligus menyimpan pesan pertama.
      // Jika chat sudah ada, API hanya mengembalikan chat tersebut.
      final response = await ApiClient.dio.post<dynamic>(
        '/chat-klarifikasi-packing',
        data: {
          'no_pesanan': widget.initialNoPesanan,
          'client_request_id': _draftMessageId,
          if (widget.initialIdPerProduk != null)
            'id_per_produk': widget.initialIdPerProduk,
          'pesan': isi,
        },
        options: options,
      );
      final body = _map(response.data);
      if (body['success'] != true) {
        throw const FormatException('Server tidak mengonfirmasi percakapan.');
      }
      final chatId = int.tryParse('${_map(body['data'])['id']}');
      if (chatId == null || chatId <= 0) {
        throw const FormatException('ID percakapan tidak ditemukan.');
      }

      if (body['pesan_pertama'] == null) {
        // Chat dibuat pengguna lain setelah pengecekan awal.
        // Kirim menggunakan UUID agar retry pada endpoint pesan idempoten.
        await ApiClient.dio.post<dynamic>(
          '/chat-klarifikasi-packing/$chatId/pesan',
          data: {
            'pesan': isi,
            'client_message_id': _draftMessageId,
          },
          options: options,
        );
      }
      _openDetail(chatId);
    } catch (error) {
      if (!mounted) return;

      // Untuk timeout/koneksi terputus, POST mungkin telah diproses server.
      // Cari chat lebih dulu. Jika ada, buka percakapan tanpa POST ulang.
      // Pengguna bisa memeriksa apakah pesan tersimpan sebelum mencoba lagi.
      final ambiguous = error is DioException &&
          (error.response == null ||
              (error.response?.statusCode ?? 0) >= 500);
      if (ambiguous && options != null) {
        try {
          final chatId = await _findChatId(options);
          if (!mounted) return;
          if (chatId != null) {
            _openDetail(chatId, recovered: true);
            return;
          }
        } catch (_) {
          // Pencarian gagal: tampilkan error dan pertahankan draf.
        }
      }
      if (mounted) {
        setState(() {
          _error = _errorText(error);
        });
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Chat Klarifikasi')),
      body: SafeArea(
        child: Column(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 12,
              ),
              color: Theme.of(context).colorScheme.surfaceContainerLow,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Pesanan Meta', style: TextStyle(fontSize: 12)),
                  Text(
                    widget.initialNoPesanan,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'Belum ada percakapan untuk pesanan ini.\n'
                    'Tulis pesan di bawah untuk memulai chat.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 6,
                ),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _message,
                      enabled: !_sending,
                      minLines: 1,
                      maxLines: 4,
                      maxLength: 10000,
                      textInputAction: TextInputAction.newline,
                      decoration: const InputDecoration(
                        hintText: 'Ketik pesan klarifikasi...',
                        border: OutlineInputBorder(),
                        counterText: '',
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    tooltip: 'Kirim pesan',
                    onPressed: _sending || _message.text.trim().isEmpty
                        ? null
                        : _sendFirstMessage,
                    icon: _sending
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
