import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../app/app_theme.dart';
import '../../../core/network/api_client.dart';
import '../../auth/pages/login_page.dart';
import '../../auth/services/auth_service.dart';
import '../../chat/pages/chat_create_page.dart';
import '../../chat/pages/chat_list_page.dart';
import '../../chat/pages/chat_inbox_refresh_bus.dart';
import '../../profile/pages/profile_page.dart';
import 'packing_dashboard_page.dart';
import 'packing_history_page.dart';
import 'packing_photo_page.dart';
import 'packing_scan_page.dart';

class PackingShell extends StatefulWidget {
  const PackingShell({super.key});

  @override
  State<PackingShell> createState() => _PackingShellState();
}

class _PackingShellState extends State<PackingShell>
    with WidgetsBindingObserver {
  static const _storage = FlutterSecureStorage();

  // ID halaman tetap: 0 Beranda, 1 Foto Meta, 2 Scan Kirim,
  // 3 Riwayat, 4 Chat, 5 Profil. Indeks bottom bar menyesuaikan platform.
  int selectedIndex = 0;
  int chatRefreshKey = 0;
  int unreadCount = 0;
  int photoCount = 0;
  int readyCount = 0;
  String? _platform;
  bool isLoggingOut = false;
  bool _appActive = true;
  bool _checkingChat = false;
  bool _checkingQueue = false;
  Timer? _chatTimer;
  StreamSubscription<void>? _inboxChanges;
  Timer? _queueTimer;

  bool get _isMeta => _platform == 'meta';

  List<int> get _visibleTabs =>
      _isMeta ? const [0, 1, 2, 3, 4, 5] : const [0, 2, 3, 5];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initialize();
    _inboxChanges = ChatInboxRefreshBus.changes.listen((_) {
      if (_isMeta) {
        _refreshChatUnread();
      }
    });
    _chatTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _refreshChatUnread(),
    );
    _queueTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _refreshQueueBadges(),
    );
  }

  Future<void> _initialize() async {
    try {
      final token = await _storage.read(key: 'auth_token');
      String? platform = (await _storage.read(key: 'user_platform'))
          ?.trim()
          .toLowerCase();

      // Bila sesi lama belum menyimpan platform, ambil dari /me.
      if (platform != 'meta' &&
          platform != 'marketplace' &&
          token != null &&
          token.isNotEmpty) {
        final response = await ApiClient.dio.get<dynamic>(
          '/me',
          options: _authOptions(token),
        );
        final body = _asMap(response.data);
        final user = _asMap(body['user']);
        platform = user['platform']?.toString().trim().toLowerCase();
        if (platform == 'meta' || platform == 'marketplace') {
          await _storage.write(key: 'user_platform', value: platform);
        }
      }

      if (!mounted) return;
      // Gagal mengenali platform: hanya tampilkan menu umum (lebih aman).
      setState(() {
        _platform = platform == 'meta' ? 'meta' : 'marketplace';
        if (!_visibleTabs.contains(selectedIndex)) selectedIndex = 0;
      });
      await _refreshQueueBadges();
      if (_isMeta) await _refreshChatUnread();
    } catch (_) {
      if (!mounted) return;
      setState(() => _platform = 'marketplace');
      await _refreshQueueBadges();
    }
  }

  static Map<String, dynamic> _asMap(Object? value) =>
      value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

  Options _authOptions(String token) => Options(
    headers: {'Authorization': 'Bearer $token', 'Accept': 'application/json'},
  );

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appActive = state == AppLifecycleState.resumed;
    if (_appActive) {
      _refreshQueueBadges();
      if (_isMeta) _refreshChatUnread();
    }
  }

  Future<void> _refreshQueueBadges() async {
    if (!mounted ||
        !_appActive ||
        isLoggingOut ||
        _checkingQueue ||
        _platform == null) {
      return;
    }

    _checkingQueue = true;

    try {
      final token = await _storage.read(key: 'auth_token');
      if (token == null || token.isEmpty) return;
      final options = _authOptions(token);

      // Ambil jumlah antrean siap dikirim dari endpoint yang sama dengan
      // menu Scan Kirim. Tidak menggunakan angka dashboard (rumus berbeda).
      try {
        final response = await ApiClient.dio.get<dynamic>(
          '/packing/antrian/ready',
          options: options,
        );
        final body = _asMap(response.data);
        final raw = body['data'];
        if (body['success'] == true && raw is List) {
          final total = raw.where((item) {
            if (_isMeta) return true;
            final platform = _asMap(item)['platform']?.toString().toLowerCase();
            return platform != 'meta';
          }).length;
          if (mounted && readyCount != total) {
            setState(() => readyCount = total);
          }
        }
      } catch (_) {
        // Jika API siap kirim gagal, pertahankan angka terakhir.
      }

      if (_isMeta) {
        // Antrean Foto Meta: hitung hanya pesanan yang SUDAH memiliki resi,
        // sama dengan filter pada PackingPhotoPage.
        try {
          final response = await ApiClient.dio.get<dynamic>(
            '/packing/antrian',
            options: options,
          );
          final body = _asMap(response.data);
          final raw = body['data'];
          if (body['success'] == true && raw is List) {
            final total = raw.where((item) {
              final resi = _asMap(item)['no_resi']?.toString().trim() ?? '';
              return resi.isNotEmpty;
            }).length;
            if (mounted && photoCount != total) {
              setState(() => photoCount = total);
            }
          }
        } catch (_) {
          // Jangan tampilkan angka palsu bila server gagal.
        }
      }
    } finally {
      _checkingQueue = false;
    }
  }

  Future<void> _refreshChatUnread() async {
    if (!mounted || !_appActive || isLoggingOut || _checkingChat || !_isMeta) {
      return;
    }
    _checkingChat = true;
    try {
      final token = await _storage.read(key: 'auth_token');
      if (token == null || token.isEmpty) return;
      final response = await ApiClient.dio.get<dynamic>(
        '/chat-klarifikasi-packing',
        queryParameters: const {'page': 1, 'per_page': 1},
        options: _authOptions(token),
      );
      final body = _asMap(response.data);
      if (!body.containsKey('jumlah_belum_dibaca_total')) return;
      final raw = body['jumlah_belum_dibaca_total'];
      final count = raw is num ? raw.toInt() : int.tryParse('$raw');
      if (count != null && mounted && unreadCount != count) {
        setState(() => unreadCount = count < 0 ? 0 : count);
      }
    } on DioException {
      // Gangguan jaringan tidak menghentikan navigasi.
    } catch (_) {
      // Pertahankan badge terakhir yang valid.
    } finally {
      _checkingChat = false;
    }
  }

  void changePage(int pageId) {
    if (!_visibleTabs.contains(pageId)) return;
    final leavingChat = selectedIndex == 4;
    setState(() {
      selectedIndex = pageId;
      if (pageId == 4) chatRefreshKey++;
    });
    if (pageId == 1 || pageId == 2 || leavingChat) {
      _refreshQueueBadges();
    }
    if (_isMeta && (pageId == 4 || leavingChat)) _refreshChatUnread();
  }

  Future<void> openCreateChat() async {
    if (!_isMeta) return;
    await Navigator.of(context)
        .push(MaterialPageRoute<bool>(builder: (_) => const ChatCreatePage()));
    if (!mounted) return;
    setState(() => chatRefreshKey++);
    _refreshChatUnread();
  }

  Future<void> logout() async {
    if (isLoggingOut) return;
    setState(() => isLoggingOut = true);
    try {
      await AuthService().logout();
      if (!mounted) return;
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const LoginPage()),
        (route) => false,
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error.toString().replaceFirst('Exception: ', '')),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => isLoggingOut = false);
    }
  }

  Widget _badgedIcon(IconData icon, int count) {
    if (count <= 0) return Icon(icon);
    return Badge(label: Text(count > 99 ? '99+' : '$count'), child: Icon(icon));
  }

  BottomNavigationBarItem _itemFor(int pageId) {
    switch (pageId) {
      case 0:
        return const BottomNavigationBarItem(
          icon: Icon(Icons.home_outlined),
          activeIcon: Icon(Icons.home),
          label: 'Beranda',
        );
      case 1:
        return BottomNavigationBarItem(
          icon: _badgedIcon(Icons.add_a_photo_outlined, photoCount),
          activeIcon: _badgedIcon(Icons.add_a_photo, photoCount),
          label: 'Foto Meta',
        );
      case 2:
        return BottomNavigationBarItem(
          icon: _badgedIcon(Icons.qr_code_scanner, readyCount),
          activeIcon: _badgedIcon(Icons.qr_code_scanner, readyCount),
          label: 'Scan Kirim',
        );
      case 3:
        return const BottomNavigationBarItem(
          icon: Icon(Icons.history_outlined),
          activeIcon: Icon(Icons.history),
          label: 'Riwayat',
        );
      case 4:
        return BottomNavigationBarItem(
          icon: _badgedIcon(Icons.chat_bubble_outline, unreadCount),
          activeIcon: _badgedIcon(Icons.chat_bubble, unreadCount),
          label: 'Chat',
        );
      default:
        return const BottomNavigationBarItem(
          icon: Icon(Icons.person_outline),
          activeIcon: Icon(Icons.person),
          label: 'Profil',
        );
    }
  }

  @override
  void dispose() {
    _inboxChanges?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _chatTimer?.cancel();
    _queueTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_platform == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final tabs = _visibleTabs;
    final pages = <Widget>[
      PackingDashboardPage(
        isActive: selectedIndex == 0,
        onOpenPhoto: () => changePage(1),
        onOpenScan: () => changePage(2),
      ),
      if (_isMeta) const PackingPhotoPage(),
      const PackingScanPage(),
      const PackingHistoryPage(),
      if (_isMeta) ChatListPage(key: ValueKey(chatRefreshKey)),
      ProfilePage(onLogout: logout),
    ];
    final navIndex = tabs.indexOf(selectedIndex);

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: IndexedStack(index: navIndex < 0 ? 0 : navIndex, children: pages),
      floatingActionButton: _isMeta && selectedIndex == 4
          ? FloatingActionButton.extended(
              onPressed: openCreateChat,
              icon: const Icon(Icons.add_comment_outlined),
              label: const Text('Buat Chat'),
            )
          : null,
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: navIndex < 0 ? 0 : navIndex,
        onTap: (index) => changePage(tabs[index]),
        type: BottomNavigationBarType.fixed,
        backgroundColor: Colors.white,
        selectedItemColor: AppTheme.primary,
        unselectedItemColor: const Color(0xFF8393A4),
        selectedFontSize: 11,
        unselectedFontSize: 10,
        selectedLabelStyle: const TextStyle(fontWeight: FontWeight.bold),
        showSelectedLabels: true,
        showUnselectedLabels: true,
        items: tabs.map(_itemFor).toList(),
      ),
    );
  }
}

// Dipertahankan jika ada halaman lain yang mereferensikannya.
class PackingPlaceholderPage extends StatelessWidget {
  final String title;
  final String description;
  final IconData icon;

  const PackingPlaceholderPage({
    super.key,
    required this.title,
    required this.description,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 88,
                height: 88,
                decoration: BoxDecoration(
                  color: const Color(0xFFE8F3FB),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Icon(icon, color: AppTheme.primary, size: 42),
              ),
              const SizedBox(height: 20),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: AppTheme.navy,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 9),
              Text(
                description,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.black54,
                  fontSize: 13,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Halaman sedang disiapkan',
                style: TextStyle(color: Colors.black38, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
