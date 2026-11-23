import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../core/network/api_client.dart';

class AuthService {
  final Dio _dio = ApiClient.dio;

  final FlutterSecureStorage _storage =
      const FlutterSecureStorage();

  // LOGIN
  Future<Map<String, dynamic>> login({
    required String username,
    required String password,
  }) async {
    try {
      final response = await _dio.post(
        '/login',
        data: {
          'name': username,
          'password': password,
        },
      );

      return Map<String, dynamic>.from(
        response.data as Map,
      );
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        throw Exception('Username atau password salah.');
      }

      if (e.response?.statusCode == 422) {
        throw Exception(
          'Username atau password tidak valid.',
        );
      }

      throw Exception(_networkError(e));
    }
  }

  Future<Map<String, dynamic>?> checkToken() async {
    final token = await _storage.read(
      key: 'auth_token',
    );

    if (token == null || token.isEmpty) {
      return null;
    }

    try {
      final response = await _dio.get(
        '/me',
        options: Options(
          headers: {
            'Authorization': 'Bearer $token',
          },
        ),
      );

      final data = Map<String, dynamic>.from(
        response.data as Map,
      );

      return data;
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        await clearSession();
        return null;
      }

      // Jangan hapus sesi jika hanya internet
      // atau server sedang bermasalah.
      throw Exception(_networkError(e));
    }
  }

  Future<void> logout() async {
    final token = await _storage.read(
      key: 'auth_token',
    );

    if (token == null || token.isEmpty) {
      await clearSession();
      return;
    }

    try {
      await _dio.post(
        '/logout',
        options: Options(
          headers: {
            'Authorization': 'Bearer $token',
          },
        ),
      );

      await clearSession();
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        // Token sudah tidak valid di server.
        await clearSession();
        return;
      }

      throw Exception(_networkError(e));
    }
  }

  // HAPUS DATA SESI LOKAL
  Future<void> clearSession() async {
    for (final key in [
      'auth_token',
      'user_id',
      'username',
      'user_role',
      'user_leader',
      'user_platform',
    ]) {
      await _storage.delete(key: key);
    }
  }

  String _networkError(DioException e) {
    if (e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.receiveTimeout ||
        e.type == DioExceptionType.connectionError) {
      return 'Tidak dapat terhubung ke server Laravel.';
    }

    if (e.response?.statusCode == 500) {
      return 'Terjadi gangguan pada server Laravel.';
    }

    return 'Request API gagal. '
        'Status: ${e.response?.statusCode ?? "Tidak diketahui"}';
  }
}
