import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../app/app_theme.dart';
import '../../../core/network/api_client.dart';
import '../../auth/pages/login_page.dart';
import '../../auth/services/auth_service.dart';

import 'cs_dashboard_page.dart';
import 'cs_orders_page.dart';
import 'cs_add_order_page.dart';
import 'cs_summary_page.dart';
import '../../profile/pages/profile_page.dart';
import '../../chat/pages/chat_list_page.dart';
import '../../chat/pages/chat_inbox_refresh_bus.dart';

class CsShell extends StatefulWidget {
  const CsShell({super.key});

  @override
  State<CsShell> createState() => _CsShellState();
}

class _CsShellState extends State<CsShell> with WidgetsBindingObserver {
  static const _storage = FlutterSecureStorage();
  static const _refreshInterval = Duration(seconds: 20);

  int selectedIndex = 0;
  int _unreadCount = 0;
  bool isLoggingOut = false;
  bool _refreshingUnread = false;
  Timer? _unreadTimer;
  StreamSubscription<void>? _inboxChanges;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshUnread();
    _inboxChanges = ChatInboxRefreshBus.changes.listen((_) => _refreshUnread());
    _unreadTimer = Timer.periodic(_refreshInterval, (_) => _refreshUnread());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshUnread();
    }
  }

  static Map<String, dynamic> _asMap(Object? value) {
    if (value is Map) return Map<String, dynamic>.from(value);
    return <String, dynamic>{};
  }

  static int _asInt(Object? value) => int.tryParse('$value') ?? 0;

  Future<void> _refreshUnread() async {
    if (!mounted || isLoggingOut || _refreshingUnread) return;
    _refreshingUnread = true;
    try {
      final token = await _storage.read(key: 'auth_token');
      if (token == null || token.isEmpty || !mounted || isLoggingOut) return;

      final response = await ApiClient.dio.get<dynamic>(
        '/chat-klarifikasi-packing',
        queryParameters: const {'page': 1, 'per_page': 1},
        options: Options(headers: {
          'Authorization': 'Bearer $token',
          'Accept': 'application/json',
        }),
      );
      final body = _asMap(response.data);
      // Field ini disediakan controller Laravel terbaru di level respons utama.
      final rawTotal = body['jumlah_belum_dibaca_total'];
      if (rawTotal == null || !mounted || isLoggingOut) return;
      final total = _asInt(rawTotal);
      if (total != _unreadCount) {
        setState(() => _unreadCount = total < 0 ? 0 : total);
      }
    } catch (_) {
      // Jika jaringan bermasalah, angka terakhir tetap ditampilkan.
      // Timer akan mencoba lagi pada interval berikutnya.
    } finally {
      _refreshingUnread = false;
    }
  }

  void changePage(int index) {
    if (selectedIndex != index) {
      setState(() => selectedIndex = index);
    }
    // Muat kembali ketika masuk/keluar dari menu Chat.
    if (index == 4 || selectedIndex != 4) {
      _refreshUnread();
    }
  }

  Widget _chatIcon(IconData iconData) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Icon(iconData),
        if (_unreadCount > 0)
          Positioned(
            right: -13,
            top: -8,
            child: Container(
              constraints: const BoxConstraints(minWidth: 17, minHeight: 17),
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: Colors.red.shade700,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white, width: 1.5),
              ),
              child: Text(
                _unreadCount > 99 ? '99+' : '$_unreadCount',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                  height: 1.1,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Future<void> logout() async {
    if (isLoggingOut) return;
    setState(() => isLoggingOut = true);
    _unreadTimer?.cancel();

    try {
      await AuthService().logout();
      if (!mounted) return;

      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const LoginPage()),
        (route) => false,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.toString().replaceFirst('Exception: ', '')),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => isLoggingOut = false);
        if (_unreadTimer?.isActive != true) {
          _unreadTimer = Timer.periodic(_refreshInterval, (_) => _refreshUnread());
        }
      }
    }
  }

  @override
  void dispose() {
    _inboxChanges?.cancel();
    _unreadTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      CsDashboardPage(onOpenOrders: () => changePage(1)),
      CsOrdersPage(onAddOrder: () => changePage(2)),
      CsAddOrderPage(onCancel: () => changePage(1)),
      const CsSummaryPage(),
      const ChatListPage(),
      ProfilePage(onLogout: logout),
    ];

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: IndexedStack(index: selectedIndex, children: pages),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: selectedIndex,
        onTap: changePage,
        type: BottomNavigationBarType.fixed,
        backgroundColor: Colors.white,
        selectedItemColor: AppTheme.primary,
        unselectedItemColor: const Color(0xFF8393A4),
        selectedFontSize: 10,
        unselectedFontSize: 9,
        selectedLabelStyle: const TextStyle(fontWeight: FontWeight.bold),
        showSelectedLabels: true,
        showUnselectedLabels: true,
        items: [
          const BottomNavigationBarItem(
            icon: Icon(Icons.home_outlined),
            activeIcon: Icon(Icons.home),
            label: 'Beranda',
          ),
          const BottomNavigationBarItem(
            icon: Icon(Icons.receipt_long_outlined),
            activeIcon: Icon(Icons.receipt_long),
            label: 'Pesanan',
          ),
          const BottomNavigationBarItem(
            icon: Icon(Icons.add_circle_outline),
            activeIcon: Icon(Icons.add_circle),
            label: 'Tambah',
          ),
          const BottomNavigationBarItem(
            icon: Icon(Icons.bar_chart_outlined),
            activeIcon: Icon(Icons.bar_chart),
            label: 'Ringkasan',
          ),
          BottomNavigationBarItem(
            icon: _chatIcon(Icons.chat_bubble_outline),
            activeIcon: _chatIcon(Icons.chat_bubble),
            label: 'Chat',
          ),
          const BottomNavigationBarItem(
            icon: Icon(Icons.person_outline),
            activeIcon: Icon(Icons.person),
            label: 'Profil',
          ),
        ],
      ),
    );
  }
}
