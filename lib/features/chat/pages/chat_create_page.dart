import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../core/network/api_client.dart';
import 'chat_detail_page.dart';

class ChatCreatePage extends StatefulWidget {
  const ChatCreatePage({super.key, this.initialNoPesanan, this.initialIdPerProduk});

  final String? initialNoPesanan;
  final int? initialIdPerProduk;

  @override
  State<ChatCreatePage> createState() => _ChatCreatePageState();
}

class _ChatCreatePageState extends State<ChatCreatePage> {
  static const _storage = FlutterSecureStorage();
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _noPesanan;
  late final TextEditingController _idPerProduk;
  final _topik = TextEditingController();
  final _pesan = TextEditingController();

  bool _sending = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _noPesanan = TextEditingController(text: widget.initialNoPesanan ?? '');
    _idPerProduk = TextEditingController(
      text: widget.initialIdPerProduk?.toString() ?? '',
    );
  }

  @override
  void dispose() {
    _noPesanan.dispose();
    _idPerProduk.dispose();
    _topik.dispose();
    _pesan.dispose();
    super.dispose();
  }

  static Map<String, dynamic> _asMap(Object? value) {
    if (value is Map) return Map<String, dynamic>.from(value);
    return <String, dynamic>{};
  }

  static String _errorText(Object error) {
    if (error is DioException) {
      final body = _asMap(error.response?.data);
      final message = body['message']?.toString();
      if (message != null && message.isNotEmpty) return message;
      return 'Gagal membuat chat (HTTP ${error.response?.statusCode ?? '-'}).';
    }
    return error.toString().replaceFirst('Exception: ', '');
  }

  Future<void> _createChat() async {
    if (_sending || !(_formKey.currentState?.validate() ?? false)) return;

    setState(() {
      _sending = true;
      _error = null;
    });

    try {
      final token = await _storage.read(key: 'auth_token');
      if (token == null || token.isEmpty) {
        throw Exception('Sesi login tidak ditemukan. Silakan login kembali.');
      }

      final productText = _idPerProduk.text.trim();
      final response = await ApiClient.dio.post<dynamic>(
        '/chat-klarifikasi-packing',
        data: {
          'no_pesanan': _noPesanan.text.trim(),
          if (productText.isNotEmpty)
            'id_per_produk': int.parse(productText),
          'topik': _topik.text.trim(),
          'pesan': _pesan.text.trim(),
        },
        options: Options(headers: {
          'Authorization': 'Bearer $token',
          'Accept': 'application/json',
          'Content-Type': 'application/json',
        }),
      );

      final responseBody = _asMap(response.data);
      final chat = _asMap(responseBody['data']);
      final chatId = int.tryParse('${chat['id']}');
      if (chatId == null || chatId <= 0) {
        throw Exception('Chat berhasil dikirim tetapi ID percakapan tidak ditemukan.');
      }

      if (!mounted) return;
      // Backend mengembalikan 200 jika chat sudah dibuat oleh akun lain.
      // Pesan dari formulir tidak dikirim ulang dalam kasus tersebut.
      final alreadyExists = response.statusCode == 200;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(alreadyExists
              ? 'Percakapan sudah tersedia. Pesan pada formulir belum dikirim; silakan kirim dari dalam chat.'
              : 'Chat klarifikasi berhasil dibuat.'),
        ),
      );

      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ChatDetailPage(chatId: chatId),
        ),
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = _errorText(error));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Buat Chat Klarifikasi')),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text(
                'Gunakan chat ini untuk klarifikasi pesanan antara CS Meta dan Packing Meta. Satu pesanan hanya memiliki satu percakapan.',
              ),
              const SizedBox(height: 20),
              TextFormField(
                controller: _noPesanan,
                enabled: !_sending && (widget.initialNoPesanan?.trim().isNotEmpty != true),
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(
                  labelText: 'Nomor pesanan *',
                  hintText: 'Contoh: 20261116003Z',
                  border: OutlineInputBorder(),
                ),
                validator: (value) {
                  final text = (value ?? '').trim();
                  if (text.isEmpty) return 'Nomor pesanan wajib diisi.';
                  if (text.length > 50) return 'Maksimal 50 karakter.';
                  return null;
                },
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _idPerProduk,
                enabled: !_sending,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'ID per produk (opsional)',
                  hintText: 'Kosongkan jika pertanyaan untuk seluruh pesanan',
                  border: OutlineInputBorder(),
                ),
                validator: (value) {
                  final text = (value ?? '').trim();
                  if (text.isEmpty) return null;
                  final number = int.tryParse(text);
                  if (number == null || number <= 0) {
                    return 'Masukkan ID produk berupa angka positif.';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _topik,
                enabled: !_sending,
                textCapitalization: TextCapitalization.sentences,
                maxLength: 255,
                decoration: const InputDecoration(
                  labelText: 'Topik klarifikasi *',
                  hintText: 'Contoh: Konfirmasi warna produk',
                  border: OutlineInputBorder(),
                ),
                validator: (value) => (value ?? '').trim().isEmpty
                    ? 'Topik wajib diisi.'
                    : null,
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _pesan,
                enabled: !_sending,
                textCapitalization: TextCapitalization.sentences,
                keyboardType: TextInputType.multiline,
                minLines: 4,
                maxLines: 7,
                maxLength: 10000,
                decoration: const InputDecoration(
                  labelText: 'Pesan pertama *',
                  hintText: 'Tulis pertanyaan atau informasi untuk CS/Packing Meta...',
                  alignLabelWithHint: true,
                  border: OutlineInputBorder(),
                ),
                validator: (value) => (value ?? '').trim().isEmpty
                    ? 'Pesan tidak boleh kosong.'
                    : null,
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ],
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _sending ? null : _createChat,
                icon: _sending
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send_outlined),
                label: Text(_sending ? 'Mengirim...' : 'Buat Chat & Kirim Pesan'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
