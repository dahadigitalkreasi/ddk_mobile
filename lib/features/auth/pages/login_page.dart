import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../app/app_theme.dart';

// DASHBOARD
import '../../cs/pages/cs_shell.dart';
import '../../leader_cs/pages/leader_shell.dart';
import '../../packing/pages/packing_shell.dart';

// SERVICE LOGIN
import '../services/auth_service.dart';

// UPDATE APLIKASI
import '../widgets/github_update_button.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  // CONTROLLER
  final usernameController = TextEditingController();
  final passwordController = TextEditingController();

  // SERVICE
  final AuthService authService = AuthService();
  final FlutterSecureStorage secureStorage =
      const FlutterSecureStorage();

  bool obscurePassword = true;
  bool isLoading = false;

  @override
  void dispose() {
    usernameController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  void showMessage(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  bool isLeader(dynamic value) {
    return value == true ||
        value == 1 ||
        value?.toString().toLowerCase() == 'true' ||
        value?.toString() == '1';
  }

  Widget? getDashboard(
    String role,
    bool leader,
  ) {
    switch (role.toLowerCase()) {
      case 'pegawai':
      case 'cs':
        return leader
            ? const LeaderShell()
            : const CsShell();

      case 'leader_cs':
        return const LeaderShell();

      case 'packing':
        return const PackingShell();

      default:
        return null;
    }
  }

  // LOGIN KE LARAVEL API
  Future<void> login() async {
    if (isLoading) return;

    final username = usernameController.text.trim();
    final password = passwordController.text;

    if (username.isEmpty || password.isEmpty) {
      showMessage(
        'Username dan password wajib diisi.',
      );
      return;
    }

    setState(() {
      isLoading = true;
    });

    try {
      final result = await authService.login(
        username: username,
        password: password,
      );

      if (!mounted) return;

      if (result['status'] != 'success') {
        showMessage(
          result['message']?.toString() ??
              'Login gagal.',
        );
        return;
      }

      final token = result['token']?.toString();

      if (token == null || token.isEmpty) {
        showMessage(
          'Token tidak ditemukan pada response API.',
        );
        return;
      }

      final user = Map<String, dynamic>.from(
        result['user'] as Map,
      );

      final role = user['role']?.toString() ?? '';
      final leader = isLeader(user['leader']);
      final platform = user['platform']?.toString().trim().toLowerCase();

      final dashboard = getDashboard(role, leader);

      if (dashboard == null) {
        showMessage(
          'Role $role belum memiliki dashboard '
          'di DDK Mobile.',
        );
        return;
      }

      // SIMPAN TOKEN DAN DATA USER
      await secureStorage.write(
        key: 'auth_token',
        value: token,
      );

      await secureStorage.write(
        key: 'user_id',
        value: user['id'].toString(),
      );

      await secureStorage.write(
        key: 'username',
        value: user['name'].toString(),
      );

      await secureStorage.write(
        key: 'user_role',
        value: role,
      );

      await secureStorage.write(
        key: 'user_leader',
        value: leader.toString(),
      );

      // Platform menentukan cakupan data (terutama modul Packing).
      // Hapus nilai lama bila API tidak memberikan platform yang valid.
      if (platform == 'meta' || platform == 'marketplace') {
        await secureStorage.write(
          key: 'user_platform',
          value: platform,
        );
      } else {
        await secureStorage.delete(key: 'user_platform');
      }

      if (!mounted) return;

      // MASUK DASHBOARD SESUAI ROLE
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => dashboard,
        ),
      );
    } catch (error) {
      showMessage(
        error.toString().replaceFirst(
          'Exception: ',
          '',
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF3F6FA),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(
              horizontal: 24,
              vertical: 28,
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: 420,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // LOGO
                  ClipRRect(
                    borderRadius: BorderRadius.circular(26),
                    child: Image.asset(
                      'assets/images/ddk_logo.png',
                      width: 130,
                      height: 130,
                      fit: BoxFit.contain,
                    ),
                  ),

                  const SizedBox(height: 20),

                  const Text(
                    'Daha Digital Kreasi',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 25,
                      fontWeight: FontWeight.bold,
                      color: AppTheme.navy,
                    ),
                  ),

                  const SizedBox(height: 6),

                  const Text(
                    'Masuk ke sistem operasional',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.black54,
                      fontSize: 14,
                    ),
                  ),

                  const SizedBox(height: 32),

                  // FORM LOGIN
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: const Color(0xFFE5EBF2),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment:
                          CrossAxisAlignment.stretch,
                      children: [
                        const Text(
                          'Halaman Login',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.bold,
                            color: AppTheme.navy,
                          ),
                        ),

                        const SizedBox(height: 6),

                        const Text(
                          'Masukkan username dan password '
                          'akun karyawan.',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.black54,
                          ),
                        ),

                        const SizedBox(height: 22),

                        // USERNAME
                        TextField(
                          controller: usernameController,
                          enabled: !isLoading,
                          textInputAction: TextInputAction.next,
                          decoration: const InputDecoration(
                            labelText: 'Username',
                            hintText: 'Masukkan username',
                            prefixIcon: Icon(
                              Icons.person_outline,
                            ),
                          ),
                        ),

                        const SizedBox(height: 16),

                        // PASSWORD
                        TextField(
                          controller: passwordController,
                          enabled: !isLoading,
                          obscureText: obscurePassword,
                          textInputAction: TextInputAction.done,
                          onSubmitted: (_) => login(),
                          decoration: InputDecoration(
                            labelText: 'Password',
                            prefixIcon: const Icon(
                              Icons.lock_outline,
                            ),
                            suffixIcon: IconButton(
                              tooltip: obscurePassword
                                  ? 'Tampilkan password'
                                  : 'Sembunyikan password',
                              icon: Icon(
                                obscurePassword
                                    ? Icons.visibility_off_outlined
                                    : Icons.visibility_outlined,
                              ),
                              onPressed: () {
                                setState(() {
                                  obscurePassword =
                                      !obscurePassword;
                                });
                              },
                            ),
                          ),
                        ),

                        const SizedBox(height: 24),

                        // TOMBOL LOGIN
                        SizedBox(
                          width: double.infinity,
                          height: 52,
                          child: FilledButton(
                            onPressed: isLoading ? null : login,
                            child: isLoading
                                ? const SizedBox(
                                    width: 22,
                                    height: 22,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.center,
                                    children: [
                                      Icon(Icons.login, size: 20),
                                      SizedBox(width: 10),
                                      Text(
                                        'Masuk',
                                        style: TextStyle(
                                          fontSize: 16,
                                          fontWeight:
                                              FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                          ),
                        ),

                        // TOMBOL UPDATE
                        const SizedBox(height: 12),
                        const GithubUpdateButton(),
                      ],
                    ),
                  ),

                  const SizedBox(height: 24),

                  const Text(
                    '© PT Daha Digital Kreasi',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.black45,
                    ),
                  ),

                  const SizedBox(height: 5),

                  const Text(
                    'Sistem Operasional Internal',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.black38,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}