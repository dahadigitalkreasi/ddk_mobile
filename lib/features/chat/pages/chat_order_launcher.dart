import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../core/network/api_client.dart';
import 'chat_first_message_page.dart';
import 'chat_detail_page.dart';

class ChatOrderLauncher {
  ChatOrderLauncher._();

  static const _storage = FlutterSecureStorage();

  static Future<void> open(
    BuildContext context, {
    required String noPesanan,
    int? idPerProduk,
  }) async {
    final number = noPesanan.trim();
    if (number.isEmpty) {
      _error(context, 'Nomor pesanan tidak ditemukan.');
      return;
    }

    // Tampilkan indikator tanpa menutup halaman detail asli.
    bool dialogOpen = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    try {
      final token = await _storage.read(key: 'auth_token');
      if (token == null || token.isEmpty) {
        throw StateError('Sesi login tidak ditemukan. Silakan login kembali.');
      }

      final response = await ApiClient.dio.get<dynamic>(
        '/chat-klarifikasi-packing/pesanan/${Uri.encodeComponent(number)}',
        options: Options(headers: {
          'Authorization': 'Bearer $token',
          'Accept': 'application/json',
        }),
      );
      final body = response.data;
      if (body is! Map || body['success'] != true || body['exists'] is! bool) {
        throw const FormatException('Format respons pencarian chat tidak sesuai.');
      }

      if (!context.mounted) return;
      if (dialogOpen) {
        Navigator.of(context, rootNavigator: true).pop();
        dialogOpen = false;
      }
      if (!context.mounted) return;

      if (body['exists'] == true) {
        final data = body['data'];
        final chatId = data is Map ? int.tryParse('${data['id']}') : null;
        if (chatId == null || chatId <= 0) {
          throw const FormatException('ID chat tidak ditemukan dalam respons API.');
        }
        await Navigator.of(context).push<void>(
          MaterialPageRoute<void>(builder: (_) => ChatDetailPage(chatId: chatId)),
        );
      } else {
        await Navigator.of(context).push<bool>(
          MaterialPageRoute<bool>(
            builder: (_) => ChatFirstMessagePage(
              initialNoPesanan: number,
              initialIdPerProduk: idPerProduk,
            ),
          ),
        );
      }
    } catch (error) {
      if (!context.mounted) return;
      if (dialogOpen) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      if (!context.mounted) return;
      if (error is DioException) {
        final data = error.response?.data;
        final message = data is Map ? data['message']?.toString() : null;
        _error(context, message?.isNotEmpty == true
            ? message!
            : 'Gagal membuka chat (HTTP ${error.response?.statusCode ?? '-'}).');
      } else {
        _error(context, error.toString().replaceFirst('Bad state: ', '').replaceFirst('FormatException: ', ''));
      }
    }
  }

  static void _error(BuildContext context, String message) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }
}
