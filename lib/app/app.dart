import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'app_theme.dart';
import '../features/auth/pages/login_page.dart';
import '../features/auth/services/auth_service.dart';
import '../features/cs/pages/cs_shell.dart';
import '../features/leader_cs/pages/leader_shell.dart';
import '../features/packing/pages/packing_shell.dart';

class DahaDigitalKreasiApp extends StatelessWidget {
  const DahaDigitalKreasiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DahaDigitalKreasi',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      home: const AuthGate(),
    );
  }
}

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  final AuthService _authService = AuthService();
  static const FlutterSecureStorage _storage = FlutterSecureStorage();

  bool _loading = true;
  String? _error;
  Map<String, dynamic>? _user;

  @override
  void initState() {
    super.initState();
    _checkSession();
  }

  static bool _isLeader(Object? value) {
    if (value == true || value == 1) return true;
    final normalized = value?.toString().trim().toLowerCase();
    return normalized == '1' || normalized == 'true';
  }

  Future<void> _syncUserSession(Map<String, dynamic> user) async {
    final id = user['id']?.toString();
    final name = user['name']?.toString();
    final role = user['role']?.toString().trim().toLowerCase() ?? '';
    final platform = user['platform']?.toString().trim().toLowerCase();

    if (id != null && id.isNotEmpty) {
      await _storage.write(key: 'user_id', value: id);
    }
    if (name != null && name.isNotEmpty) {
      await _storage.write(key: 'username', value: name);
    }
    await _storage.write(key: 'user_role', value: role);
    await _storage.write(
      key: 'user_leader',
      value: _isLeader(user['leader']).toString(),
    );

    // Jangan simpan platform lama apabila respons API tidak memiliki platform.
    if (platform == 'meta' || platform == 'marketplace') {
      await _storage.write(key: 'user_platform', value: platform);
    } else {
      await _storage.delete(key: 'user_platform');
    }
  }

  Future<void> _checkSession() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final result = await _authService.checkToken();
      final rawUser = result?['user'];
      final user = rawUser is Map
          ? Map<String, dynamic>.from(rawUser)
          : null;

      if (user != null) {
        await _syncUserSession(user);
      }

      if (!mounted) return;
      setState(() {
        _user = user;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _loading = false;
      });
    }
  }

  Widget _buildDashboard(Map<String, dynamic> user) {
    final role = user['role']?.toString().trim().toLowerCase() ?? '';
    final leader = _isLeader(user['leader']);

    switch (role) {
      case 'pegawai':
      case 'cs':
        return leader ? const LeaderShell() : const CsShell();

      // Kompatibilitas jika masih ada akun dengan role lama.
      case 'leader_cs':
        return const LeaderShell();

      case 'packing':
        return const PackingShell();

      default:
        return Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'Role $role belum memiliki dashboard.',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    if (_error != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.wifi_off_rounded, size: 56),
                const SizedBox(height: 16),
                const Text(
                  'Tidak dapat memeriksa sesi login.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(_error!, textAlign: TextAlign.center),
                const SizedBox(height: 20),
                ElevatedButton(
                  onPressed: _checkSession,
                  child: const Text('Coba Lagi'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (_user == null) {
      return const LoginPage();
    }

    return _buildDashboard(_user!);
  }
}