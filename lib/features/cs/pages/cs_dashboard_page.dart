import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../app/app_theme.dart';
import '../../../core/network/api_client.dart';
import '../../orders/services/cs_order_updates.dart';

class CsDashboardPage extends StatefulWidget {
  final VoidCallback onOpenOrders;
  final bool isActive;

  const CsDashboardPage({
    super.key,
    required this.onOpenOrders,
    this.isActive = true,
  });

  @override
  State<CsDashboardPage> createState() => _CsDashboardPageState();
}

class _CsDashboardPageState extends State<CsDashboardPage>
    with WidgetsBindingObserver {
  static const _storage = FlutterSecureStorage();
  static const _refreshInterval = Duration(seconds: 30);
  Timer? _refreshTimer;
  bool _appResumed = true;

  bool _loading = true;
  bool _refreshing = false;
  String? _error;
  String? _ordersError;
  String _name = 'Customer Service';
  _CsDashboardData? _dashboard;
  List<_CsOrderPreview> _recentOrders = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    CsOrderUpdates.version.addListener(_onOrderCreated);
    if (widget.isActive) {
      _loadData();
    }
    _refreshTimer = Timer.periodic(_refreshInterval, (_) {
      if (widget.isActive && _appResumed) {
        _loadData();
      }
    });
  }

  @override
  void didUpdateWidget(covariant CsDashboardPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.isActive && widget.isActive && _appResumed) {
      _loadData();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final wasResumed = _appResumed;
    _appResumed = state == AppLifecycleState.resumed;
    if (!wasResumed && _appResumed && widget.isActive) {
      _loadData();
    }
  }

  void _onOrderCreated() {
    if (mounted) {
      _loadData();
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    CsOrderUpdates.version.removeListener(_onOrderCreated);
    super.dispose();
  }

  Future<Map<String, dynamic>> _getJson(
    String path,
    String token,
  ) async {
    final response = await ApiClient.dio.get<dynamic>(
      path,
      options: Options(headers: {'Authorization': 'Bearer $token'}),
    );
    final data = response.data;
    if (data is! Map) {
      throw const FormatException('Format respons API tidak sesuai.');
    }
    return Map<String, dynamic>.from(data);
  }

  Future<Map<String, dynamic>> _getDashboard(
    String token,
    String? userId,
  ) async {
    try {
      return await _getJson('/dashboard/cs', token);
    } on DioException catch (e) {
      // Dokumentasi menyebut /dashboard/cs, tetapi contoh mencantumkan /dashboard/cs/{id}.
      // Hanya coba versi ber-ID jika route pertama benar-benar tidak ditemukan.
      if (e.response?.statusCode != 404 || userId == null || userId.isEmpty) {
        rethrow;
      }
      return _getJson('/dashboard/cs/${Uri.encodeComponent(userId)}', token);
    }
  }

  Future<void> _loadData() async {
    if (_refreshing) return;
    _refreshing = true;
    if (mounted) {
      setState(() {
        _loading = _dashboard == null;
        _error = null;
        _ordersError = null;
      });
    }

    try {
      final token = await _storage.read(key: 'auth_token');
      final userId = await _storage.read(key: 'user_id');
      final name = await _storage.read(key: 'username');
      if (token == null || token.isEmpty) {
        throw StateError('Sesi login tidak ditemukan. Silakan login ulang.');
      }

      // Data kartu dashboard tidak bergantung pada keberhasilan daftar terbaru.
      final response = await _getDashboard(token, userId);
      if (response['success'] != true || response['data'] is! Map) {
        throw const FormatException('Data dashboard dari API tidak valid.');
      }
      final dashboard = _CsDashboardData.fromJson(
        Map<String, dynamic>.from(response['data'] as Map),
      );
      if (!mounted) return;
      setState(() {
        _dashboard = dashboard;
        if (name != null && name.trim().isNotEmpty) _name = name.trim();
        _loading = false;
      });

      try {
        final ordersResponse = await _getJson('/pesanan', token);
        final raw = ordersResponse['data'];
        if (ordersResponse['success'] != true || raw is! List) {
          throw const FormatException('Daftar pesanan dari API tidak valid.');
        }
        final orders = raw
            .whereType<Map>()
            .map((e) => _CsOrderPreview.fromJson(Map<String, dynamic>.from(e)))
            .take(3)
            .toList();
        if (mounted) {
          setState(() {
            _recentOrders = orders;
            _ordersError = null;
          });
        }
      } catch (e) {
        if (mounted) {
          setState(() {
            _recentOrders = [];
            _ordersError = _readableError(e);
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = _readableError(e);
          _loading = false;
        });
      }
    } finally {
      _refreshing = false;
    }
  }

  String _readableError(Object error) {
    if (error is DioException) {
      final status = error.response?.statusCode;
      if (status == 401) return 'Sesi login tidak valid. Silakan login ulang.';
      if (status == 403) return 'Akun ini tidak memiliki akses ke data CS.';
      if (status == 404) return 'Endpoint dashboard tidak ditemukan di Laravel.';
      if (status != null && status >= 500) return 'Server Laravel mengalami masalah (HTTP $status).';
      if (error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.receiveTimeout ||
          error.type == DioExceptionType.connectionError) {
        return 'Tidak dapat terhubung ke Laravel. Periksa koneksi dan alamat IP API.';
      }
      return 'Gagal mengambil data dari Laravel${status != null ? ' (HTTP $status)' : ''}.';
    }
    if (error is FormatException || error is StateError) return error.toString().replaceFirst(RegExp(r'^(FormatException|Bad state): '), '');
    return 'Gagal memuat data dashboard.';
  }

  String _rupiah(num value) {
    final digits = value.round().toString();
    return 'Rp${digits.replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (m) => '.')}';
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: RefreshIndicator(
        onRefresh: _loadData,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            _buildHeader(),
            Padding(
              padding: const EdgeInsets.all(15),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text('Ringkasan Pesanan', style: TextStyle(
                          fontSize: 17, fontWeight: FontWeight.bold,
                          color: AppTheme.navy,
                        )),
                      ),
                      IconButton(
                        tooltip: 'Muat ulang',
                        onPressed: _refreshing ? null : _loadData,
                        icon: const Icon(Icons.refresh, color: AppTheme.navy),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  if (_loading)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 38),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (_error != null)
                    _ErrorPanel(message: _error!, onRetry: _loadData)
                  else if (_dashboard != null) ...[
                    Row(children: [
                      Expanded(child: _StatCard(
                        title: 'Total Pesanan',
                        value: '${_dashboard!.totalPesanan}',
                        icon: Icons.receipt_long_outlined,
                        iconColor: const Color(0xFF1873B4),
                      )),
                      const SizedBox(width: 10),
                      Expanded(child: _StatCard(
                        title: 'Dalam Proses',
                        value: '${_dashboard!.dalamProses}',
                        icon: Icons.schedule_outlined,
                        iconColor: const Color(0xFFA65A04),
                      )),
                    ]),
                    const SizedBox(height: 10),
                    Row(children: [
                      Expanded(child: _StatCard(
                        title: 'Dikirim',
                        value: '${_dashboard!.dikirim}',
                        icon: Icons.local_shipping_outlined,
                        iconColor: const Color(0xFF1873B4),
                      )),
                      const SizedBox(width: 10),
                      Expanded(child: _StatCard(
                        title: 'Selesai',
                        value: '${_dashboard!.selesai}',
                        icon: Icons.check_circle_outline,
                        iconColor: const Color(0xFF0B8B65),
                      )),
                    ]),
                    const SizedBox(height: 15),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(17),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: const Color(0xFFE5EBF2)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Total Omzet', style: TextStyle(
                            color: Color(0xFF708095), fontSize: 12,
                          )),
                          const SizedBox(height: 8),
                          Text(_rupiah(_dashboard!.omzet), style: const TextStyle(
                            fontSize: 26, fontWeight: FontWeight.bold,
                            color: AppTheme.navy,
                          )),
                          const SizedBox(height: 7),
                          const Text('Pesanan Meta sesuai cakupan API dashboard CS',
                            style: TextStyle(fontSize: 11, color: Colors.black45)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 22),
                    Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                      const Text('Pesanan Terbaru', style: TextStyle(
                        fontSize: 17, fontWeight: FontWeight.bold,
                        color: AppTheme.navy,
                      )),
                      TextButton(onPressed: widget.onOpenOrders, child: const Text('Lihat Semua')),
                    ]),
                    const SizedBox(height: 5),
                    if (_ordersError != null)
                      _ErrorPanel(message: _ordersError!, onRetry: _loadData)
                    else if (_recentOrders.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 20),
                        child: Center(child: Text('Belum ada pesanan Meta untuk akun ini.')),
                      )
                    else
                      for (final order in _recentOrders) ...[
                        _OrderPreviewCard(
                          orderNumber: order.noPesanan,
                          buyer: order.namaPembeli,
                          price: _rupiah(order.totalHarga),
                          status: order.status,
                          statusColor: _statusColor(order.status),
                        ),
                        const SizedBox(height: 9),
                      ],
                  ],
                  const SizedBox(height: 20),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Color _statusColor(String status) {
    switch (status.toLowerCase()) {
      case 'proses': return const Color(0xFFA65A04);
      case 'kirim': return const Color(0xFF1873B4);
      case 'selesai': return const Color(0xFF0B8B65);
      case 'batal': return const Color(0xFFB42318);
      default: return const Color(0xFF61758A);
    }
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 24),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF103961), Color(0xFF145B91)],
          begin: Alignment.topLeft, end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(24)),
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
            const Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('DAHA DIGITAL KREASI', style: TextStyle(
                  color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                SizedBox(height: 3),
                Text('CS Workspace', style: TextStyle(
                  color: Color(0xFFD2E5F7), fontSize: 11)),
              ],
            )),
            IconButton(
              onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Notifikasi akan tersedia nanti.'))),
              icon: const Icon(Icons.notifications_none, color: Colors.white),
            ),
          ]),
          const SizedBox(height: 22),
          Text('Halo, $_name!', style: const TextStyle(
            color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
          const SizedBox(height: 5),
          const Text('Pantau pekerjaan dan pesananmu.', style: TextStyle(
            color: Color(0xFFD2E5F7), fontSize: 12)),
          const SizedBox(height: 15),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(30),
              border: Border.all(color: Colors.white.withValues(alpha: 0.20)),
            ),
            child: const Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.person_outline, color: Colors.white, size: 16),
              SizedBox(width: 7),
              Text('Role: Customer Service', style: TextStyle(
                color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600)),
            ]),
          ),
        ],
      ),
    );
  }
}

class _CsDashboardData {
  final int totalPesanan;
  final int dalamProses;
  final int dikirim;
  final int selesai;
  final num omzet;

  const _CsDashboardData({
    required this.totalPesanan,
    required this.dalamProses,
    required this.dikirim,
    required this.selesai,
    required this.omzet,
  });

  factory _CsDashboardData.fromJson(Map<String, dynamic> json) {
    num number(Object? value) => value is num
        ? value
        : num.tryParse(value?.toString() ?? '') ?? 0;
    return _CsDashboardData(
      totalPesanan: number(json['totalPesanan']).toInt(),
      dalamProses: number(json['proses']).toInt(),
      dikirim: number(json['dikirim']).toInt(),
      selesai: number(json['selesai']).toInt(),
      omzet: number(json['omzet']),
    );
  }
}

class _CsOrderPreview {
  final String noPesanan;
  final String namaPembeli;
  final num totalHarga;
  final String status;

  const _CsOrderPreview({
    required this.noPesanan,
    required this.namaPembeli,
    required this.totalHarga,
    required this.status,
  });

  factory _CsOrderPreview.fromJson(Map<String, dynamic> json) {
    final rawHarga = json['total_harga'];
    return _CsOrderPreview(
      noPesanan: json['no_pesanan']?.toString() ?? '-',
      namaPembeli: json['nama_pembeli']?.toString() ?? '-',
      totalHarga: rawHarga is num ? rawHarga : num.tryParse(rawHarga?.toString() ?? '') ?? 0,
      status: json['status']?.toString() ?? '-',
    );
  }
}

class _ErrorPanel extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorPanel({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFFE5EBF2)),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(children: [
        const Icon(Icons.error_outline, color: Color(0xFFB42318), size: 32),
        const SizedBox(height: 9),
        Text(message, textAlign: TextAlign.center),
        const SizedBox(height: 12),
        OutlinedButton.icon(onPressed: onRetry,
          icon: const Icon(Icons.refresh), label: const Text('Coba Lagi')),
      ]),
    );
  }
}

class _StatCard extends StatelessWidget {
  final String title;
  final String value;
  final IconData icon;
  final Color iconColor;

  const _StatCard({
    required this.title, required this.value,
    required this.icon, required this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE5EBF2)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(title, style: const TextStyle(
            fontSize: 11, color: Color(0xFF708095)))),
          Icon(icon, color: iconColor, size: 21),
        ]),
        const SizedBox(height: 10),
        Text(value, style: const TextStyle(
          fontSize: 25, fontWeight: FontWeight.bold, color: AppTheme.navy)),
      ]),
    );
  }
}

class _OrderPreviewCard extends StatelessWidget {
  final String orderNumber;
  final String buyer;
  final String price;
  final String status;
  final Color statusColor;

  const _OrderPreviewCard({
    required this.orderNumber, required this.buyer,
    required this.price, required this.status, required this.statusColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: const Color(0xFFE5EBF2)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(orderNumber, style: const TextStyle(
            fontSize: 13, fontWeight: FontWeight.bold, color: AppTheme.navy))),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(status.toUpperCase(), style: TextStyle(
              fontSize: 10, fontWeight: FontWeight.bold, color: statusColor)),
          ),
        ]),
        const SizedBox(height: 8),
        Text(buyer, style: const TextStyle(fontSize: 12, color: Color(0xFF61758A))),
        const SizedBox(height: 11),
        const Divider(height: 1),
        const SizedBox(height: 11),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          const Text('Total Harga', style: TextStyle(
            fontSize: 11, color: Color(0xFF708095))),
          Text(price, style: const TextStyle(
            fontSize: 13, fontWeight: FontWeight.bold, color: AppTheme.navy)),
        ]),
      ]),
    );
  }
}