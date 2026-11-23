import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../app/app_theme.dart';
import '../../../core/network/api_client.dart';

class PackingHistoryPage extends StatefulWidget {
  const PackingHistoryPage({super.key});

  @override
  State<PackingHistoryPage> createState() => _PackingHistoryPageState();
}

class _PackingHistoryPageState extends State<PackingHistoryPage>
    with WidgetsBindingObserver {
  static const _storage = FlutterSecureStorage();
  final _searchController = TextEditingController();
  final List<Map<String, dynamic>> _orders = [];

  Timer? _searchTimer;
  Timer? _refreshTimer;
  String? _token;
  String? _platform;
  String? _error;
  bool _loading = true;
  int _requestSequence = 0;
  String _selectedChannel = 'SEMUA';
  DateTime? _selectedDate;

  static const _channels = ['SEMUA', 'META', 'SHOPEE', 'TIKTOK'];

  static Map<String, dynamic> _map(Object? value) => value is Map
      ? Map<String, dynamic>.from(value)
      : <String, dynamic>{};

  static String _text(Object? value, {String fallback = '-'}) {
    final result = value?.toString().trim() ?? '';
    return result.isEmpty ? fallback : result;
  }

  static String _two(int number) => number.toString().padLeft(2, '0');

  static String _apiDate(DateTime date) =>
      '${date.year}-${_two(date.month)}-${_two(date.day)}';

  static String _displayDate(DateTime date) =>
      '${_two(date.day)}/${_two(date.month)}/${date.year}';

  static String _apiError(Object error) {
    if (error is DioException) {
      final body = _map(error.response?.data);
      final message = body['message']?.toString();
      if (message != null && message.isNotEmpty) return message;
      if (error.response?.statusCode == 401) {
        return 'Sesi login tidak valid. Silakan login kembali.';
      }
      return 'Gagal mengambil riwayat (HTTP ${error.response?.statusCode ?? '-'}).';
    }
    return error.toString().replaceFirst('Exception: ', '');
  }

  Options get _authOptions => Options(headers: {
        'Authorization': 'Bearer $_token',
        'Accept': 'application/json',
      });

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initialize();
    _refreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted && !_loading && _token != null &&
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
        _loadHistory(silent: true);
      }
    });
  }

  Future<void> _initialize() async {
    try {
      final token = await _storage.read(key: 'auth_token');
      final platform = await _storage.read(key: 'user_platform');
      if (token == null || token.isEmpty) {
        throw Exception('Sesi login tidak ditemukan. Silakan login kembali.');
      }
      if (!mounted) return;
      _token = token;
      _platform = platform?.toLowerCase();
      await _loadHistory();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = _apiError(error);
        _loading = false;
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _token != null && mounted) {
      _loadHistory(silent: true);
    }
  }

  Future<void> _loadHistory({bool silent = false}) async {
    if (_token == null) return;
    final requestId = ++_requestSequence;
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final search = _searchController.text.trim();
      final response = await ApiClient.dio.get<dynamic>(
        '/packing/riwayat',
        queryParameters: {
          if (search.isNotEmpty) 'search': search,
          // Di backend saat ini 'tanggal' memfilter batas_kirim_at,
          // bukan tanggal aktual saat paket di-scan.
          if (_selectedDate != null) 'tanggal': _apiDate(_selectedDate!),
          if (_selectedChannel == 'SHOPEE') 'marketplace': 'Shopee',
          if (_selectedChannel == 'TIKTOK') 'marketplace': 'TikTok',
        },
        options: _authOptions,
      );
      final payload = _map(response.data);
      if (payload['success'] != true) {
        throw Exception(_text(payload['message'], fallback: 'Gagal mengambil riwayat.'));
      }
      final raw = payload['data'];
      if (raw is! List) {
        throw Exception('Format data riwayat tidak sesuai respons API.');
      }
      if (!mounted || requestId != _requestSequence) return;
      setState(() {
        _orders
          ..clear()
          ..addAll(raw.map(_map));
        _error = null;
      });
    } catch (error) {
      if (!mounted || requestId != _requestSequence) return;
      setState(() {
        _orders.clear();
        _error = _apiError(error);
      });
    } finally {
      if (mounted && requestId == _requestSequence) {
        setState(() => _loading = false);
      }
    }
  }

  void _onSearchChanged(String _) {
    setState(() {});
    _searchTimer?.cancel();
    _searchTimer = Timer(const Duration(milliseconds: 450), _loadHistory);
  }

  Future<void> _chooseDate() async {
    final now = DateTime.now();
    final chosen = await showDatePicker(
      context: context,
      initialDate: _selectedDate ?? now,
      firstDate: DateTime(2020),
      lastDate: DateTime(now.year + 5),
    );
    if (!mounted || chosen == null) return;
    setState(() => _selectedDate = chosen);
    await _loadHistory();
  }

  void _resetFilters() {
    _searchTimer?.cancel();
    _searchController.clear();
    setState(() {
      _selectedChannel = 'SEMUA';
      _selectedDate = null;
    });
    _loadHistory();
  }

  String _channel(Map<String, dynamic> order) {
    if (_text(order['platform'], fallback: '').toLowerCase() == 'meta') {
      return 'META';
    }
    final marketplace = _text(order['marketplace'], fallback: '').toUpperCase();
    if (marketplace == 'SHOPEE' || marketplace == 'TIKTOK') return marketplace;
    return 'MARKETPLACE';
  }

  List<Map<String, dynamic>> get _filteredOrders {
    return _orders.where((order) {
      // Pembatasan ini hanya untuk tampilan aplikasi. Hak akses sesungguhnya
      // tetap perlu dijaga di backend Laravel.
      if (_platform == 'marketplace' &&
          _text(order['platform']).toLowerCase() == 'meta') {
        return false;
      }
      if (_selectedChannel == 'SEMUA') return true;
      return _channel(order) == _selectedChannel;
    }).toList();
  }

  Color _channelColor(String channel) {
    switch (channel) {
      case 'META':
        return const Color(0xFF1873B4);
      case 'SHOPEE':
        return const Color(0xFFE76A22);
      case 'TIKTOK':
        return const Color(0xFF0F6970);
      default:
        return AppTheme.primary;
    }
  }

  Widget _channelBadge(String channel) {
    final color = _channelColor(channel);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(channel,
          style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.bold)),
    );
  }

  Widget _detailRow(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 112,
              child: Text(label,
                  style: const TextStyle(fontSize: 12, color: Colors.black54))),
          Expanded(child: Text(value,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
        ]),
      );

  void _showDetail(Map<String, dynamic> order) {
    final channel = _channel(order);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: SingleChildScrollView(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Detail Riwayat Pengiriman', style: TextStyle(
                  fontSize: 19, fontWeight: FontWeight.bold, color: AppTheme.navy)),
              const SizedBox(height: 15),
              Row(children: [
                Expanded(child: Text(_text(order['noResi']), style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.navy))),
                _channelBadge(channel),
              ]),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: const Color(0xFFEAF7F0),
                    borderRadius: BorderRadius.circular(11)),
                child: const Row(children: [
                  Icon(Icons.check_circle, color: Color(0xFF0B8B65)),
                  SizedBox(width: 9),
                  Expanded(child: Text('Dikirim Internal',
                      style: TextStyle(color: Color(0xFF0B8B65),
                          fontWeight: FontWeight.bold))),
                ]),
              ),
              const SizedBox(height: 18),
              _detailRow('Nomor Resi', _text(order['noResi'])),
              _detailRow('Pesanan', _text(order['noPesanan'])),
              _detailRow('Pembeli', _text(order['pembeli'])),
              _detailRow('Platform', _text(order['platform'])),
              _detailRow('Marketplace', _text(order['marketplace'])),
              _detailRow('Kurir', _text(order['kurir'])),
              const SizedBox(height: 12),
              const Text(
                'Riwayat ini mencatat status Dikirim Internal, bukan bukti '
                'paket sudah diterima ekspedisi atau pembeli.',
                style: TextStyle(color: Colors.black54, fontSize: 11, height: 1.5),
              ),
              const SizedBox(height: 16),
              SizedBox(width: double.infinity, child: FilledButton(
                onPressed: () => Navigator.pop(sheetContext),
                child: const Text('Tutup Detail'),
              )),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _historyCard(Map<String, dynamic> order) {
    final channel = _channel(order);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE5EBF2)),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _showDetail(order),
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.all(15),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text(_text(order['noResi']),
                    style: const TextStyle(fontSize: 14,
                        fontWeight: FontWeight.bold, color: AppTheme.navy))),
                _channelBadge(channel),
              ]),
              const SizedBox(height: 11),
              Text(_text(order['pembeli']),
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Text('Pesanan: ${_text(order['noPesanan'])}',
                  style: const TextStyle(fontSize: 12, color: Color(0xFF61758A))),
              const SizedBox(height: 10),
              _detailRow('Kurir', _text(order['kurir'])),
              const Divider(height: 15),
              Row(children: [
                const Icon(Icons.check_circle, size: 16, color: Color(0xFF0B8B65)),
                const SizedBox(width: 5),
                const Expanded(child: Text('Dikirim Internal', style: TextStyle(
                    color: Color(0xFF0B8B65), fontSize: 11, fontWeight: FontWeight.bold))),
                const Text('Lihat Detail', style: TextStyle(
                    color: AppTheme.primary, fontSize: 11,
                    fontWeight: FontWeight.w600)),
                const Icon(Icons.chevron_right, color: AppTheme.primary, size: 18),
              ]),
            ]),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _requestSequence++;
    _searchTimer?.cancel();
    _refreshTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final orders = _filteredOrders;
    return SafeArea(
      child: Column(children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(18, 20, 18, 24),
          decoration: const BoxDecoration(
            gradient: LinearGradient(colors: [Color(0xFF103961), Color(0xFF145B91)]),
            borderRadius: BorderRadius.vertical(bottom: Radius.circular(24)),
          ),
          child: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Riwayat Pengiriman', style: TextStyle(
                fontSize: 23, fontWeight: FontWeight.bold, color: Colors.white)),
            SizedBox(height: 6),
            Text('Pesanan yang sudah diproses secara internal',
                style: TextStyle(fontSize: 12, color: Color(0xFFD2E5F7))),
          ]),
        ),
        Expanded(child: RefreshIndicator(
          onRefresh: _loadHistory,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(15),
            children: [
              Container(
                padding: const EdgeInsets.all(15),
                decoration: BoxDecoration(color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFFE5EBF2))),
                child: Row(children: [
                  const Icon(Icons.local_shipping_outlined,
                      color: Color(0xFF0B8B65), size: 31),
                  const SizedBox(width: 13),
                  Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${orders.length}', style: const TextStyle(
                        fontSize: 25, fontWeight: FontWeight.bold, color: AppTheme.navy)),
                    const Text('Resi Dikirim Internal',
                        style: TextStyle(color: Colors.black54, fontSize: 12)),
                  ]),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Muat ulang',
                    onPressed: _loading ? null : _loadHistory,
                    icon: const Icon(Icons.refresh),
                  ),
                ]),
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFFE5EBF2))),
                child: Column(children: [
                  TextField(
                    controller: _searchController,
                    onChanged: _onSearchChanged,
                    onSubmitted: (_) {
                      _searchTimer?.cancel();
                      _loadHistory();
                    },
                    decoration: InputDecoration(
                      hintText: 'Cari resi / nomor / pembeli...',
                      hintStyle: const TextStyle(fontSize: 12),
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: _searchController.text.isEmpty ? null : IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () {
                          _searchController.clear();
                          _loadHistory();
                          setState(() {});
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    key: ValueKey(_selectedChannel),
                    initialValue: _selectedChannel,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Filter Channel',
                      prefixIcon: Icon(Icons.storefront_outlined),
                    ),
                    items: _channels
                        .where((channel) => _platform != 'marketplace' || channel != 'META')
                        .map((channel) => DropdownMenuItem(
                          value: channel,
                          child: Text(channel == 'SEMUA' ? 'Semua Channel' : channel),
                        )).toList(),
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() => _selectedChannel = value);
                      _loadHistory();
                    },
                  ),
                  const SizedBox(height: 12),
                  SizedBox(width: double.infinity, child: OutlinedButton.icon(
                    onPressed: _chooseDate,
                    icon: const Icon(Icons.calendar_month_outlined),
                    label: Text(_selectedDate == null
                        ? 'Filter Tanggal Batas Kirim'
                        : 'Batas kirim: ${_displayDate(_selectedDate!)}'),
                  )),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: _resetFilters,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Reset Filter'),
                    ),
                  ),
                ]),
              ),
              const SizedBox(height: 18),
              Row(children: [
                const Expanded(child: Text('Daftar Riwayat', style: TextStyle(
                    fontSize: 17, fontWeight: FontWeight.bold, color: AppTheme.navy))),
                Text('${orders.length} resi', style: const TextStyle(
                    fontSize: 12, color: Colors.black54)),
              ]),
              const SizedBox(height: 12),
              if (_loading) const Padding(
                padding: EdgeInsets.symmetric(vertical: 35),
                child: Center(child: CircularProgressIndicator()),
              ) else ...[
                if (_error != null) ...[
                  Text(_error!, style: const TextStyle(color: Colors.red)),
                  const SizedBox(height: 10),
                  OutlinedButton(onPressed: _loadHistory,
                      child: const Text('Coba Lagi')),
                ] else if (orders.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 42),
                    child: Center(child: Text('Belum ada riwayat pengiriman.')),
                  ) else
                  for (final order in orders) _historyCard(order),
              ],
              const SizedBox(height: 15),
              const Text(
                'Riwayat ditampilkan berdasarkan akun petugas Packing yang melakukan scan. '
                'Filter tanggal menggunakan batas kirim sesuai API Laravel.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: Colors.black45),
              ),
              const SizedBox(height: 20),
            ],
          ),
        )),
      ]),
    );
  }
}
