import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../app/app_theme.dart';
import '../../../core/network/api_client.dart';
import '../../orders/services/cs_order_updates.dart';

class CsSummaryPage extends StatefulWidget {
  /// Samakan dengan status tab aktif pada halaman induk (seperti Dashboard Packing).
  final bool isActive;

  const CsSummaryPage({super.key, this.isActive = true});

  @override
  State<CsSummaryPage> createState() => _CsSummaryPageState();
}

class _CsSummaryPageState extends State<CsSummaryPage>
    with WidgetsBindingObserver {
  static const _storage = FlutterSecureStorage();
  static const _statuses = ['proses', 'packing', 'dikirim', 'selesai', 'batal'];
  _SummaryData? _summary;
  List<_SummaryOrder> _orders = [];
  String? _summaryError;
  String? _ordersError;
  bool _loading = true;
  bool _refreshing = false;
  int _requestId = 0;
  Timer? _refreshTimer;
  bool _appResumed = true;
  DateTime? _lastUpdated;

  bool _hasLoadedOnce = false;
  bool _pendingRefresh = false;
  static const _refreshInterval = Duration(seconds: 30);

  void _configureAutoRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
    if (!widget.isActive || !_appResumed) return;
    _refreshTimer = Timer.periodic(_refreshInterval, (_) {
      if (mounted && !_refreshing && !_loading) {
        _load(silent: true);
      }
    });
  }

  @override
  void didUpdateWidget(covariant CsSummaryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isActive != widget.isActive) {
      _configureAutoRefresh();
      if (widget.isActive && _appResumed) {
        _load(silent: true);
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final resumed = state == AppLifecycleState.resumed;
    if (_appResumed == resumed) return;
    _appResumed = resumed;
    _configureAutoRefresh();
    if (resumed && widget.isActive) {
      _load(silent: true);
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    CsOrderUpdates.version.addListener(_onOrderCreated);
    _configureAutoRefresh();
    _load();
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _requestId++;
    WidgetsBinding.instance.removeObserver(this);
    CsOrderUpdates.version.removeListener(_onOrderCreated);
    super.dispose();
  }

  void _onOrderCreated() {
    if (mounted && widget.isActive && _appResumed) {
      _load(silent: true);
    }
  }

  Future<Map<String, dynamic>> _fetch(String path, String token) async {
    final response = await ApiClient.dio.get<dynamic>(
      path,
      options: Options(headers: {'Authorization': 'Bearer $token'}),
    );
    final body = response.data;
    if (body is! Map) {
      throw const FormatException(
        'Data belum dapat ditampilkan. Silakan coba lagi.',
      );
    }
    return Map<String, dynamic>.from(body);
  }

  Future<void> _load({bool silent = false}) async {
    if (_refreshing) {
      // Jangan hilangkan pembaruan yang terjadi saat permintaan masih berjalan.
      _pendingRefresh = true;
      return;
    }
    _refreshing = true;
    final requestId = ++_requestId;
    if (mounted) {
      setState(() {
        if (!silent && !_hasLoadedOnce) _loading = true;
        if (!silent) {
          _summaryError = null;
          _ordersError = null;
        }
      });
    }

    try {
      final token = await _storage.read(key: 'auth_token');
      if (token == null || token.isEmpty) {
        throw StateError('Sesi masuk sudah berakhir. Silakan masuk kembali.');
      }

      // Gunakan dua permintaan yang terpisah agar statistik tetap dapat tampil
      // sekalipun riwayat pesanan sedang bermasalah, dan sebaliknya.
      try {
        final response = await _fetch('/ringkasan/cs', token);
        if (response['success'] != true || response['data'] is! Map) {
          throw const FormatException(
            'Ringkasan belum dapat ditampilkan. Silakan coba lagi.',
          );
        }
        final data = _SummaryData.fromJson(
          Map<String, dynamic>.from(response['data'] as Map),
        );
        if (mounted && requestId == _requestId) {
          setState(() {
            _summary = data;
            _summaryError = null;
            _hasLoadedOnce = true;
            _lastUpdated = DateTime.now();
          });
        }
      } catch (error) {
        final urgent = _isAuthError(error);
        if (mounted &&
            requestId == _requestId &&
            (!silent || _summary == null || urgent)) {
          setState(() => _summaryError = _readableError(error));
        }
        debugPrint('Ringkasan CS gagal diperbarui: $error');
      }

      try {
        final response = await _fetch('/pesanan', token);
        if (response['success'] != true || response['data'] is! List) {
          throw const FormatException(
            'Riwayat pesanan belum dapat ditampilkan. Silakan coba lagi.',
          );
        }
        final items =
            (response['data'] as List)
                .whereType<Map>()
                .map(
                  (value) =>
                      _SummaryOrder.fromJson(Map<String, dynamic>.from(value)),
                )
                .toList()
              ..sort((a, b) => b.inputAt.compareTo(a.inputAt));
        if (mounted && requestId == _requestId) {
          setState(() {
            _orders = items.take(10).toList();
            _ordersError = null;
            _hasLoadedOnce = true;
          });
        }
      } catch (error) {
        final urgent = _isAuthError(error);
        if (mounted &&
            requestId == _requestId &&
            (!silent || !_hasLoadedOnce || urgent)) {
          setState(() => _ordersError = _readableError(error));
        }
        debugPrint('Riwayat CS gagal diperbarui: $error');
      }
    } catch (error) {
      if (mounted &&
          requestId == _requestId &&
          (!silent || !_hasLoadedOnce || _isAuthError(error))) {
        setState(() {
          _summaryError = _readableError(error);
          _ordersError = _readableError(error);
        });
      }
      debugPrint('Pembaruan Ringkasan CS gagal: $error');
    } finally {
      _refreshing = false;
      if (mounted && requestId == _requestId) {
        setState(() => _loading = false);
      }
      final rerun = _pendingRefresh;
      _pendingRefresh = false;
      if (rerun && mounted && widget.isActive && _appResumed) {
        _load(silent: true);
      }
    }
  }

  bool _isAuthError(Object error) =>
      error is DioException &&
      (error.response?.statusCode == 401 || error.response?.statusCode == 403);

  String _readableError(Object error) {
    if (error is DioException) {
      final code = error.response?.statusCode;
      if (code == 401) return 'Sesi login berakhir. Silakan login kembali.';
      if (code == 403) return 'Akun tidak memiliki akses ke data ini.';
      if (code == 404) return 'Data belum tersedia. Silakan hubungi admin.';
      if (code != null && code >= 500) {
        return 'Layanan sedang mengalami kendala. Coba lagi beberapa saat.';
      }
      if (error.type == DioExceptionType.connectionError ||
          error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.receiveTimeout) {
        return 'Koneksi terputus. Periksa internet lalu coba lagi.';
      }
      return 'Data belum berhasil dimuat. Silakan coba lagi.';
    }
    if (error is FormatException) return error.message;
    if (error is StateError) return error.message;
    return 'Gagal mengambil data. Silakan coba lagi.';
  }

  String _lastUpdateLabel() {
    if (_lastUpdated == null) {
      return 'Memuat data terbaru...';
    }
    final t = _lastUpdated!;
    String two(int n) => n.toString().padLeft(2, '0');
    return 'Diperbarui ${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  String _rupiah(num value) {
    final amount = value.round().toString().replaceAllMapped(
      RegExp(r'(\d)(?=(\d{3})+(?!\d))'),
      (match) => '${match[1]}.',
    );
    return 'Rp$amount';
  }

  String _statusLabel(String status) {
    switch (status) {
      case 'proses':
        return 'Proses';
      case 'packing':
        return 'Packing';
      case 'kirim':
      case 'dikirim':
        return 'Dikirim';
      case 'selesai':
        return 'Selesai';
      case 'batal':
        return 'Batal';
      case 'affiliate':
        return 'Affiliate';
      case 'pengembalian':
        return 'Pengembalian';
      case 'pengiriman_gagal':
        return 'Pengiriman Gagal';
      default:
        return status;
    }
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'proses':
        return const Color(0xFFA65A04);
      case 'packing':
        return const Color(0xFF6956B5);
      case 'kirim':
      case 'dikirim':
        return const Color(0xFF1873B4);
      case 'selesai':
        return const Color(0xFF0B8B65);
      case 'batal':
        return const Color(0xFFB42332);
      default:
        return Colors.grey;
    }
  }

  Widget _statCard(String label, String value, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE5EBF2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 23),
          const SizedBox(height: 12),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 21,
              fontWeight: FontWeight.bold,
              color: AppTheme.navy,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            label,
            style: const TextStyle(fontSize: 11, color: Color(0xFF708095)),
          ),
        ],
      ),
    );
  }

  Widget _panel(String title, Widget content) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE5EBF2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: AppTheme.navy,
            ),
          ),
          const SizedBox(height: 16),
          content,
        ],
      ),
    );
  }

  Widget _errorBox(String error) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        error,
        style: const TextStyle(color: Color(0xFFB42332), fontSize: 12),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: () => _load(),
        icon: const Icon(Icons.refresh),
        label: const Text('Coba Lagi'),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final summary = _summary;
    return SafeArea(
      child: RefreshIndicator(
        onRefresh: () => _load(),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(18, 20, 18, 24),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xFF103961), Color(0xFF145B91)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.vertical(
                  bottom: Radius.circular(24),
                ),
              ),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Ringkasan Saya',
                    style: TextStyle(
                      fontSize: 23,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  SizedBox(height: 6),
                  Text(
                    'Statistik pribadi Customer Service',
                    style: TextStyle(fontSize: 12, color: Color(0xFFD2E5F7)),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(15),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_loading) const LinearProgressIndicator(),
                  if (_summaryError != null)
                    _panel('Status Ringkasan', _errorBox(_summaryError!)),
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Statistik Pesanan',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.bold,
                            color: AppTheme.navy,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Perbarui ringkasan',
                        onPressed: _refreshing ? null : () => _load(),
                        icon: const Icon(Icons.refresh),
                      ),
                    ],
                  ),
                  Text(
                    _lastUpdateLabel(),
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF708095),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: _statCard(
                          'Total Pesanan',
                          '${summary?.totalPesanan ?? '-'}',
                          Icons.receipt_long_outlined,
                          AppTheme.primary,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _statCard(
                          'Pesanan Valid',
                          '${summary?.pesananValid ?? '-'}',
                          Icons.check_circle_outline,
                          const Color(0xFF0B8B65),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: _statCard(
                          'Omzet',
                          summary == null ? '-' : _rupiah(summary.omzet),
                          Icons.payments_outlined,
                          AppTheme.primary,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _statCard(
                          'Dibatalkan',
                          '${summary?.pesananBatal ?? '-'}',
                          Icons.cancel_outlined,
                          const Color(0xFFB42332),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  _panel(
                    'Distribusi Status Pesanan',
                    Column(
                      children: _statuses.map((status) {
                        final count = summary?.distribusiPesanan[status] ?? 0;
                        final total = summary?.totalPesanan ?? 0;
                        final percentage = total <= 0
                            ? 0.0
                            : (count / total).clamp(0.0, 1.0).toDouble();
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 17),
                          child: Column(
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      _statusLabel(status),
                                      style: const TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  Text(
                                    '$count pesanan',
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: Colors.black54,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 7),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: LinearProgressIndicator(
                                  value: percentage,
                                  minHeight: 9,
                                  backgroundColor: const Color(0xFFEEF2F6),
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                    _statusColor(status),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                  _panel(
                    'Riwayat Pesanan Terbaru',
                    _ordersError != null
                        ? _errorBox(_ordersError!)
                        : _orders.isEmpty
                        ? Text(
                            _loading
                                ? 'Memuat riwayat...'
                                : 'Belum ada pesanan.',
                            style: const TextStyle(color: Colors.black54),
                          )
                        : Column(
                            children: _orders
                                .map(
                                  (order) => Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 12,
                                    ),
                                    decoration: const BoxDecoration(
                                      border: Border(
                                        bottom: BorderSide(
                                          color: Color(0xFFEEF1F5),
                                        ),
                                      ),
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Expanded(
                                              child: Text(
                                                order.number,
                                                style: const TextStyle(
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.bold,
                                                  color: AppTheme.navy,
                                                ),
                                              ),
                                            ),
                                            Text(
                                              _statusLabel(order.status),
                                              style: TextStyle(
                                                fontSize: 11,
                                                fontWeight: FontWeight.w600,
                                                color: _statusColor(
                                                  order.status,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 6),
                                        Text(
                                          order.buyer,
                                          style: const TextStyle(
                                            fontSize: 12,
                                            color: Colors.black54,
                                          ),
                                        ),
                                        const SizedBox(height: 5),
                                        Text(
                                          _rupiah(order.totalHarga),
                                          style: const TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                )
                                .toList(),
                          ),
                  ),
                  _panel(
                    'Lead & Biaya Iklan',
                    const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.campaign_outlined,
                          size: 34,
                          color: AppTheme.primary,
                        ),
                        SizedBox(height: 10),
                        Text(
                          'Data Advertiser belum tersedia',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        SizedBox(height: 7),
                        Text(
                          'Lead, biaya iklan, CPC, CPO, dan rasio konversi akan ditampilkan setelah sistem Advertiser terintegrasi.',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.black54,
                            height: 1.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

int _asInt(dynamic value) =>
    value is num ? value.toInt() : int.tryParse('$value') ?? 0;
num _asNum(dynamic value) => value is num ? value : num.tryParse('$value') ?? 0;

class _SummaryData {
  final int totalPesanan;
  final int pesananValid;
  final int pesananBatal;
  final num omzet;
  final Map<String, int> distribusiPesanan;

  const _SummaryData({
    required this.totalPesanan,
    required this.pesananValid,
    required this.pesananBatal,
    required this.omzet,
    required this.distribusiPesanan,
  });

  factory _SummaryData.fromJson(Map<String, dynamic> json) {
    final raw = json['distribusiPesanan'];
    final distribution = raw is Map
        ? Map<String, dynamic>.from(raw)
        : <String, dynamic>{};
    return _SummaryData(
      totalPesanan: _asInt(json['totalPesanan']),
      pesananValid: _asInt(json['pesananValid']),
      pesananBatal: _asInt(json['pesananBatal']),
      omzet: _asNum(json['omzet']),
      distribusiPesanan: {
        for (final status in [
          'proses',
          'packing',
          'dikirim',
          'selesai',
          'batal',
        ])
          status: _asInt(distribution[status]),
      },
    );
  }
}

class _SummaryOrder {
  final String number;
  final String buyer;
  final String status;
  final num totalHarga;
  final String inputAt;

  const _SummaryOrder({
    required this.number,
    required this.buyer,
    required this.status,
    required this.totalHarga,
    required this.inputAt,
  });

  factory _SummaryOrder.fromJson(Map<String, dynamic> json) => _SummaryOrder(
    number: '${json['no_pesanan'] ?? '-'}',
    buyer: '${json['nama_pembeli'] ?? '-'}',
    status: '${json['status'] ?? '-'}',
    totalHarga: _asNum(json['total_harga']),
    inputAt: '${json['input_at'] ?? ''}',
  );
}
