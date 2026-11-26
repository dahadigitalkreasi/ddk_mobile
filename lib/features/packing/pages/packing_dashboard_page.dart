import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../app/app_theme.dart';
import '../../../core/network/api_client.dart';

class PackingDashboardPage extends StatefulWidget {
  final VoidCallback onOpenPhoto;
  final VoidCallback onOpenScan;
  final bool isActive;

  const PackingDashboardPage({
    super.key,
    required this.onOpenPhoto,
    required this.onOpenScan,
    this.isActive = true,
  });

  @override
  State<PackingDashboardPage> createState() => _PackingDashboardPageState();
}

class _PackingDashboardPageState extends State<PackingDashboardPage>
    with WidgetsBindingObserver {
  static const FlutterSecureStorage _storage = FlutterSecureStorage();

  int _totalMenunggu = 0;
  int _siapDikirim = 0;
  int _dikirim = 0;
  int _terlambat = 0;
  bool _loading = true;
  bool _refreshing = false;
  bool _hasLoadedOnce = false;
  String? _error;
  String _platform = '';
  int _requestId = 0;
  Timer? _autoRefreshTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadDashboard();
    // Poll hanya ketika tab Beranda aktif agar tidak membebani API.
    _configureAutoRefresh();
  }

  void _configureAutoRefresh() {
    _autoRefreshTimer?.cancel();
    if (!widget.isActive) return;
    _autoRefreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted && !_loading && !_refreshing) {
        _loadDashboard(silent: true);
      }
    });
  }

  @override
  void didUpdateWidget(covariant PackingDashboardPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive != oldWidget.isActive) {
      _configureAutoRefresh();
      if (widget.isActive) {
        // Segera refresh ketika kembali dari Foto Meta / Scan Kirim.
        _loadDashboard(silent: true);
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && widget.isActive && !_loading && !_refreshing) {
      _loadDashboard(silent: true);
    }
  }

  static int _asInt(Object? value) {
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  static Map<String, dynamic> _asMap(Object? value) {
    if (value is Map) return Map<String, dynamic>.from(value);
    return <String, dynamic>{};
  }

  String _errorMessage(Object error) {
    if (error is DioException) {
      final body = _asMap(error.response?.data);
      if (error.response?.statusCode == 401) {
        return 'Sesi login tidak valid. Silakan login kembali.';
      }
      if (error.response?.statusCode == 403) {
        return 'Akun tidak memiliki akses ke Dashboard Packing.';
      }
      final message = body['message']?.toString();
      if (message != null && message.isNotEmpty) return message;
      if (error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.receiveTimeout ||
          error.type == DioExceptionType.connectionError) {
        return 'Tidak dapat terhubung ke server Laravel.';
      }
      return 'Gagal memuat dashboard (HTTP ${error.response?.statusCode ?? '-'}).';
    }
    return error.toString().replaceFirst('Exception: ', '');
  }

  Future<void> _loadDashboard({bool silent = false}) async {
    if (_refreshing) return;
    final requestId = ++_requestId;
    if (mounted) {
      setState(() {
        _refreshing = true;
        // Refresh berkala tidak menghilangkan data yang sudah berhasil dimuat.
        if (!silent && !_hasLoadedOnce) _loading = true;
        if (!silent) _error = null;
      });
    }

    try {
      final token = await _storage.read(key: 'auth_token');
      final platform = await _storage.read(key: 'user_platform');
      if (token == null || token.isEmpty) {
        throw Exception('Sesi login tidak tersedia. Silakan login kembali.');
      }

      final response = await ApiClient.dio.get<dynamic>(
        '/packing/dashboard',
        options: Options(headers: {
          'Authorization': 'Bearer $token',
          'Accept': 'application/json',
        }),
      );

      final result = _asMap(response.data);
      if (result['success'] != true) {
        throw Exception(result['message']?.toString() ??
            'Dashboard Packing gagal dimuat.');
      }
      if (result['data'] is! Map) {
        throw const FormatException('Format data Dashboard Packing tidak sesuai API.');
      }
      final data = _asMap(result['data']);
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _totalMenunggu = _asInt(data['totalMenunggu']);
        _siapDikirim = _asInt(data['siapDikirim']);
        _dikirim = _asInt(data['dikirim']);
        _terlambat = _asInt(data['terlambat']);
        _platform = (platform ?? '').toLowerCase();
        _hasLoadedOnce = true;
        _error = null;
      });
    } catch (error) {
      if (!mounted || requestId != _requestId) return;
      final status = error is DioException ? error.response?.statusCode : null;
      // Error otorisasi harus tetap diberitahukan walaupun data cache ada.
      final isAuthError = status == 401 || status == 403 ||
          (error is Exception &&
              error.toString().contains('Sesi login tidak tersedia'));
      // Refresh otomatis kadang gagal karena timeout/koneksi; jangan membuat
      // banner merah ketika data sebelumnya masih valid.
      if (!silent || !_hasLoadedOnce || isAuthError) {
        setState(() => _error = _errorMessage(error));
      }
      debugPrint('Packing dashboard refresh gagal '
          '(silent=$silent, status=${status ?? '-'}): $error');
    } finally {
      if (mounted && requestId == _requestId) {
        setState(() {
          _loading = false;
          _refreshing = false;
        });
      }
    }
  }

  Widget statCard({
    required String title,
    required String value,
    required String subtitle,
    required IconData icon,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE5EBF2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 25),
          const SizedBox(height: 12),
          Text(value,
              style: const TextStyle(
                  fontSize: 25,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.navy)),
          const SizedBox(height: 5),
          Text(title,
              style: const TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w600)),
          const SizedBox(height: 5),
          Text(subtitle,
              style: const TextStyle(
                  fontSize: 10,
                  color: Color(0xFF708095),
                  height: 1.4)),
        ],
      ),
    );
  }

  Widget actionCard({
    required String title,
    required String description,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFE5EBF2)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: const Color(0xFFEAF4FD),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Icon(icon, color: AppTheme.primary, size: 26),
              ),
              const SizedBox(height: 13),
              Text(title,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                      color: AppTheme.navy)),
              const SizedBox(height: 8),
              Text(description,
                  style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF61758A),
                      height: 1.5)),
              const SizedBox(height: 12),
              const Row(children: [
                Text('Buka Menu',
                    style: TextStyle(
                        color: AppTheme.primary,
                        fontSize: 12,
                        fontWeight: FontWeight.w600)),
                SizedBox(width: 4),
                Icon(Icons.arrow_forward,
                    size: 16, color: AppTheme.primary),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  Widget ruleItem({
    required IconData icon,
    required String title,
    required String description,
    required Color color,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 21, color: color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: AppTheme.navy)),
                const SizedBox(height: 5),
                Text(description,
                    style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF61758A),
                        height: 1.5)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _requestId++;
    _autoRefreshTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isMarketplace = _platform == 'marketplace';
    return SafeArea(
      child: RefreshIndicator(
        onRefresh: () => _loadDashboard(),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 24),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xFF103961), Color(0xFF145B91)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius:
                    BorderRadius.vertical(bottom: Radius.circular(24)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Image.asset('assets/images/ddk_logo.png',
                          width: 46, height: 46, fit: BoxFit.contain),
                    ),
                    const SizedBox(width: 11),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('DAHA DIGITAL KREASI',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold)),
                          SizedBox(height: 4),
                          Text('Packing Workspace',
                              style: TextStyle(
                                  color: Color(0xFFD2E5F7), fontSize: 11)),
                        ],
                      ),
                    ),
                    const CircleAvatar(
                      backgroundColor: Color(0xFF276696),
                      child: Icon(Icons.inventory_2_outlined,
                          color: Colors.white),
                    ),
                  ]),
                  const SizedBox(height: 22),
                  const Text('Dashboard Packing',
                      style: TextStyle(
                          fontSize: 23,
                          color: Colors.white,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  const Text('Kelola foto barang dan proses pengiriman',
                      style: TextStyle(
                          fontSize: 12, color: Color(0xFFD2E5F7))),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(15),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_loading) ...[
                    const LinearProgressIndicator(),
                    const SizedBox(height: 12),
                  ],
                  if (_error != null) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFF0EE),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_error!,
                              style: const TextStyle(color: Colors.red)),
                          const SizedBox(height: 8),
                          TextButton.icon(
                            onPressed: _refreshing ? null : () => _loadDashboard(),
                            icon: const Icon(Icons.refresh),
                            label: const Text('Coba lagi'),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  Row(children: [
                    const Expanded(
                      child: Text('Ringkasan Operasional',
                          style: TextStyle(
                              color: AppTheme.navy,
                              fontSize: 17,
                              fontWeight: FontWeight.bold)),
                    ),
                    IconButton(
                      tooltip: 'Perbarui dashboard',
                      onPressed: _refreshing ? null : () => _loadDashboard(),
                      icon: const Icon(Icons.refresh),
                    ),
                  ]),
                  const SizedBox(height: 12),
                  Row(children: [
                    Expanded(
                      child: statCard(
                        title: 'Total Menunggu',
                        value: _loading && _totalMenunggu == 0 ? '...' : '$_totalMenunggu',
                        subtitle: 'Pesanan menunggu proses',
                        icon: Icons.pending_actions_outlined,
                        color: const Color(0xFFA65A04),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: statCard(
                        title: 'Siap Dikirim',
                        value: _loading && _siapDikirim == 0 ? '...' : '$_siapDikirim',
                        subtitle: 'Siap untuk pengiriman',
                        icon: Icons.inventory_2_outlined,
                        color: AppTheme.primary,
                      ),
                    ),
                  ]),
                  const SizedBox(height: 10),
                  Row(children: [
                    Expanded(
                      child: statCard(
                        title: 'Dikirim',
                        value: _loading && _dikirim == 0 ? '...' : '$_dikirim',
                        subtitle: 'Berstatus kirim',
                        icon: Icons.local_shipping_outlined,
                        color: const Color(0xFF0B8B65),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: statCard(
                        title: 'Terlambat',
                        value: _loading && _terlambat == 0 ? '...' : '$_terlambat',
                        subtitle: 'Melewati batas kirim',
                        icon: Icons.schedule_outlined,
                        color: const Color(0xFFBE4D4D),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 23),
                  const Text('Menu Operasional',
                      style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                          color: AppTheme.navy)),
                  const SizedBox(height: 12),
                  if (!isMarketplace) ...[
                    actionCard(
                      title: 'Foto Packing Meta',
                      description: 'Cari pesanan Meta, periksa produk, ambil foto barang, dan konfirmasi selesai packing.',
                      icon: Icons.add_a_photo_outlined,
                      onTap: widget.onOpenPhoto,
                    ),
                    const SizedBox(height: 12),
                  ],
                  actionCard(
                    title: 'Scan Pengiriman',
                    description: 'Proses nomor resi setelah packing selesai.',
                    icon: Icons.qr_code_scanner,
                    onTap: widget.onOpenScan,
                  ),
                  const SizedBox(height: 23),
                  const Text('Aturan Alur Packing',
                      style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                          color: AppTheme.navy)),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: const Color(0xFFE5EBF2)),
                    ),
                    child: Column(children: [
                      if (!isMarketplace)
                        ruleItem(
                          icon: Icons.camera_alt_outlined,
                          title: 'Foto Produk Meta',
                          description: 'Barang pesanan Meta wajib difoto sebelum selesai dipacking.',
                          color: AppTheme.primary,
                        ),
                      ruleItem(
                        icon: Icons.inventory_2_outlined,
                        title: 'Packing Marketplace',
                        description: 'Shopee dan TikTok menggunakan status packing dari sistem PembukuanLaser.',
                        color: const Color(0xFF6956B5),
                      ),
                      ruleItem(
                        icon: Icons.qr_code_scanner,
                        title: 'Scan Resi Pengiriman',
                        description: 'Scan nomor resi setelah paket siap dikirim.',
                        color: const Color(0xFF0B8B65),
                      ),
                      ruleItem(
                        icon: Icons.local_shipping_outlined,
                        title: 'Dikirim Internal',
                        description: 'Menandakan paket telah diproses petugas untuk pengiriman, bukan sudah diterima pembeli.',
                        color: const Color(0xFFA65A04),
                      ),
                    ]),
                  ),
                  const SizedBox(height: 20),
                  const Center(
                    child: Text('Data ringkasan diambil dari API Laravel',
                        style: TextStyle(fontSize: 11, color: Colors.black45)),
                  ),
                  const SizedBox(height: 20),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}