import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../app/app_theme.dart';
import '../../../core/network/api_client.dart';
import '../../orders/services/cs_order_updates.dart';
import 'cs_order_detail_page.dart';

/// Menampilkan daftar dengan pagination di Flutter.
/// API Laravel /pesanan tetap digunakan tanpa perubahan.
class CsOrdersPage extends StatefulWidget {
  // Tetap dipertahankan agar pemanggil lama tidak perlu diubah.
  // Tombol Tambah Pesanan tidak ditampilkan pada halaman ini.
  final VoidCallback onAddOrder;
  final bool isActive;

  const CsOrdersPage({
    super.key,
    required this.onAddOrder,
    this.isActive = true,
  });

  @override
  State<CsOrdersPage> createState() => _CsOrdersPageState();
}

class _CsOrdersPageState extends State<CsOrdersPage>
    with WidgetsBindingObserver {
  static const int _pageSize = 20;
  static const _statuses = <String>[
    'semua',
    'proses',
    'kirim',
    'selesai',
    'batal',
    'affiliate',
    'pengembalian',
    'pengiriman_gagal',
  ];

  final _storage = const FlutterSecureStorage();
  final _searchController = TextEditingController();
  final _scrollController = ScrollController();
  Timer? _searchTimer;
  Timer? _refreshTimer;
  bool _appResumed = true;
  bool _loading = true;
  bool _refreshing = false;
  bool _hasLoaded = false;
  String? _error;
  String _selectedStatus = 'semua';
  List<_CsOrder> _orders = [];
  int _page = 1;
  int _requestId = 0;

  int get _pageCount =>
      _orders.isEmpty ? 1 : (_orders.length + _pageSize - 1) ~/ _pageSize;
  int get _safePage => _page.clamp(1, _pageCount).toInt();
  int get _firstIndex => (_safePage - 1) * _pageSize;
  int get _visibleCount =>
      (_orders.length - _firstIndex).clamp(0, _pageSize).toInt();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    CsOrderUpdates.version.addListener(_onOrderUpdated);
    _loadOrders();
    _startRefreshTimer();
  }

  void _startRefreshTimer() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted && widget.isActive && _appResumed && !_refreshing) {
        _loadOrders(silent: true);
      }
    });
  }

  @override
  void didUpdateWidget(covariant CsOrdersPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.isActive && widget.isActive) {
      _loadOrders(silent: true);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appResumed = state == AppLifecycleState.resumed;
    if (_appResumed && widget.isActive) {
      _loadOrders(silent: true);
    }
  }

  void _onOrderUpdated() {
    if (mounted) {
      _loadOrders(silent: _hasLoaded);
    }
  }

  @override
  void dispose() {
    _searchTimer?.cancel();
    _refreshTimer?.cancel();
    _requestId++;
    WidgetsBinding.instance.removeObserver(this);
    CsOrderUpdates.version.removeListener(_onOrderUpdated);
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<String> _token() async {
    final token = await _storage.read(key: 'auth_token');
    if (token == null || token.isEmpty) {
      throw StateError('Sesi login berakhir. Silakan masuk kembali.');
    }
    return token;
  }

  Future<void> _loadOrders({bool silent = false}) async {
    final requestId = ++_requestId;
    final search = _searchController.text.trim();
    final status = _selectedStatus;
    if (mounted) {
      setState(() {
        _refreshing = true;
        if (!silent && !_hasLoaded) {
          _loading = true;
        }
        if (!silent) {
          _error = null;
        }
      });
    }

    try {
      final token = await _token();
      final response = await ApiClient.dio.get<dynamic>(
        '/pesanan',
        queryParameters: {
          if (search.isNotEmpty) 'search': search,
          if (status != 'semua') 'status': status,
        },
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      final body = response.data;
      if (body is! Map || body['success'] != true || body['data'] is! List) {
        throw const FormatException('Data pesanan belum dapat ditampilkan.');
      }
      final parsed = (body['data'] as List)
          .whereType<Map>()
          .map((item) => _CsOrder.fromJson(Map<String, dynamic>.from(item)))
          .toList();
      // Supaya urutan tetap konsisten ketika ada pesanan baru.
      parsed.sort((a, b) {
        final left = DateTime.tryParse(a.date.replaceFirst(' ', 'T'));
        final right = DateTime.tryParse(b.date.replaceFirst(' ', 'T'));
        if (left != null && right != null) {
          final cmp = right.compareTo(left);
          if (cmp != 0) return cmp;
        }
        return b.number.compareTo(a.number);
      });

      if (!mounted || requestId != _requestId) return;
      setState(() {
        _orders = parsed;
        _hasLoaded = true;
        _error = null;
        _page = _safePage;
      });
    } catch (e) {
      if (!mounted || requestId != _requestId) return;
      // Kegagalan sementara tidak mengosongkan data yang sudah tampil.
      if (!silent || !_hasLoaded) {
        setState(() => _error = _errorMessage(e));
      }
    } finally {
      if (mounted && requestId == _requestId) {
        setState(() {
          _loading = false;
          _refreshing = false;
        });
      }
    }
  }

  void _onSearchChanged(String _) {
    _searchTimer?.cancel();
    setState(() => _page = 1);
    _searchTimer = Timer(const Duration(milliseconds: 450), () {
      if (mounted) _loadOrders();
    });
  }

  void _changeStatus(String status) {
    if (_selectedStatus == status) return;
    _searchTimer?.cancel();
    setState(() {
      _selectedStatus = status;
      _page = 1;
    });
    _loadOrders();
  }

  void _changePage(int next) {
    if (next < 1 || next > _pageCount || next == _safePage) return;
    setState(() => _page = next);
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    }
  }

  Future<void> _showOrderDetail(_CsOrder order) async {
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => CsOrderDetailSheet(
        noPesanan: order.number,
        namaPembeli: order.buyer,
        noResi: order.resi,
        status: order.status,
        tanggalInput: order.date,
        totalHarga: order.totalPrice,
        storage: _storage,
      ),
    );
    if (changed == true && mounted) {
      await _loadOrders(silent: true);
    }
  }

  Widget _header() {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 20, 18, 20),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF103961), Color(0xFF145B91)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(24)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFF276696),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.receipt_long_outlined, color: Colors.white),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Pesanan Saya',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                SizedBox(height: 3),
                Text(
                  'Lihat dan kelola pesanan pelanggan',
                  style: TextStyle(color: Color(0xFFD2E5F7), fontSize: 12),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Muat ulang pesanan',
            onPressed: _refreshing ? null : () => _loadOrders(),
            icon: const Icon(Icons.refresh, color: Colors.white),
          ),
        ],
      ),
    );
  }

  Widget _filterPanel() {
    return Container(
      margin: const EdgeInsets.fromLTRB(15, 14, 15, 0),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE5EBF2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _searchController,
            onChanged: _onSearchChanged,
            decoration: InputDecoration(
              hintText: 'Cari nama, pesanan, atau resi...',
              hintStyle: const TextStyle(fontSize: 13),
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _searchController.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Hapus pencarian',
                      icon: const Icon(Icons.close),
                      onPressed: () {
                        _searchTimer?.cancel();
                        _searchController.clear();
                        setState(() => _page = 1);
                        _loadOrders();
                      },
                    ),
              isDense: true,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 38,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _statuses.length,
              separatorBuilder: (_, _) => const SizedBox(width: 7),
              itemBuilder: (context, index) {
                final status = _statuses[index];
                final selected = _selectedStatus == status;
                return ChoiceChip(
                  label: Text(
                    status == 'semua' ? 'Semua' : _statusLabel(status),
                  ),
                  selected: selected,
                  showCheckmark: false,
                  onSelected: (_) => _changeStatus(status),
                  backgroundColor: const Color(0xFFF3F6FA),
                  selectedColor: const Color(0xFF103961),
                  labelStyle: TextStyle(
                    color: selected ? Colors.white : const Color(0xFF53687C),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                  side: BorderSide.none,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _pagination() {
    if (_orders.isEmpty || _pageCount <= 1) return const SizedBox.shrink();
    final from = _firstIndex + 1;
    final to = (_firstIndex + _visibleCount).clamp(0, _orders.length).toInt();
    return Padding(
      padding: const EdgeInsets.fromLTRB(15, 8, 15, 24),
      child: Container(
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: const Color(0xFFE5EBF2)),
        ),
        child: Column(
          children: [
            Text(
              'Menampilkan $from–$to dari ${_orders.length} pesanan',
              style: const TextStyle(fontSize: 12, color: Color(0xFF61758A)),
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                OutlinedButton.icon(
                  onPressed: _safePage == 1
                      ? null
                      : () => _changePage(_safePage - 1),
                  icon: const Icon(Icons.chevron_left, size: 18),
                  label: const Text('Sebelumnya'),
                ),
                Text(
                  '$_safePage / $_pageCount',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.navy,
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: _safePage == _pageCount
                      ? null
                      : () => _changePage(_safePage + 1),
                  icon: const Icon(Icons.chevron_right, size: 18),
                  label: const Text('Berikutnya'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          // Header tidak ikut dibangun ulang per kartu.
          _header(),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => _loadOrders(),
              child: CustomScrollView(
                controller: _scrollController,
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverToBoxAdapter(child: _filterPanel()),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 17, 16, 11),
                      child: Row(
                        children: [
                          const Expanded(
                            child: Text(
                              'Daftar Pesanan',
                              style: TextStyle(
                                fontSize: 16,
                                color: AppTheme.navy,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          Text(
                            _loading
                                ? 'Memuat...'
                                : '${_orders.length} pesanan',
                            style: const TextStyle(
                              fontSize: 12,
                              color: Color(0xFF61758A),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (_loading && !_hasLoaded)
                    const SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.all(36),
                        child: Center(child: CircularProgressIndicator()),
                      ),
                    )
                  else if (_error != null && _orders.isEmpty)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 15),
                        child: _MessagePanel(
                          icon: Icons.wifi_off_outlined,
                          title: 'Pesanan belum bisa dimuat',
                          description: _error!,
                          onRetry: _loadOrders,
                        ),
                      ),
                    )
                  else if (_orders.isEmpty)
                    const SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: 15),
                        child: _MessagePanel(
                          icon: Icons.search_off_outlined,
                          title: 'Pesanan tidak ditemukan',
                          description:
                              'Coba ubah pencarian atau filter status.',
                        ),
                      ),
                    )
                  else ...[
                    SliverList(
                      delegate: SliverChildBuilderDelegate((context, index) {
                        final order = _orders[_firstIndex + index];
                        return Padding(
                          padding: const EdgeInsets.fromLTRB(15, 0, 15, 9),
                          child: _OrderCard(
                            order: order,
                            onTap: () => _showOrderDetail(order),
                          ),
                        );
                      }, childCount: _visibleCount),
                    ),
                    SliverToBoxAdapter(child: _pagination()),
                  ],
                  const SliverToBoxAdapter(child: SizedBox(height: 12)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CsOrder {
  final String number;
  final String buyer;
  final String resi;
  final String status;
  final String date;
  final num totalPrice;

  const _CsOrder({
    required this.number,
    required this.buyer,
    required this.resi,
    required this.status,
    required this.date,
    required this.totalPrice,
  });

  factory _CsOrder.fromJson(Map<String, dynamic> j) => _CsOrder(
    number: _asText(j['no_pesanan']),
    buyer: _asText(j['nama_pembeli']),
    resi: _asText(j['no_resi']),
    status: _asText(j['status']).toLowerCase(),
    date: _asText(j['input_at'] ?? j['tanggal']),
    totalPrice: num.tryParse('${j['total_harga'] ?? 0}') ?? 0,
  );
}

class _OrderCard extends StatelessWidget {
  final _CsOrder order;
  final VoidCallback onTap;

  const _OrderCard({required this.order, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(15),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFE5EBF2)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      order.number,
                      style: const TextStyle(
                        color: AppTheme.navy,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  _StatusBadge(status: order.status),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF2F6FA),
                      borderRadius: BorderRadius.circular(11),
                    ),
                    child: const Icon(
                      Icons.person_outline,
                      color: Color(0xFF61758A),
                      size: 21,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          order.buyer.isEmpty
                              ? 'Nama belum tersedia'
                              : order.buyer,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          order.resi.isEmpty
                              ? 'Belum ada nomor resi'
                              : 'Resi: ${order.resi}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 11,
                            color: Color(0xFF61758A),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Divider(height: 1, color: Color(0xFFEEF1F5)),
              const SizedBox(height: 11),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _dateLabel(order.date),
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.black54,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          _rupiah(order.totalPrice),
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                            color: AppTheme.navy,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Text(
                    'Detail',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.primary,
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(
                    Icons.chevron_right,
                    size: 17,
                    color: AppTheme.primary,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MessagePanel extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final Future<void> Function()? onRetry;

  const _MessagePanel({
    required this.icon,
    required this.title,
    required this.description,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(26),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Icon(icon, size: 44, color: Colors.grey),
          const SizedBox(height: 12),
          Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.bold),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),
          Text(
            description,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.black54, fontSize: 12),
          ),
          if (onRetry != null) ...[
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: () {
                onRetry!();
              },
              icon: const Icon(Icons.refresh),
              label: const Text('Coba Lagi'),
            ),
          ],
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final String status;
  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    final color = _statusColor(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.11),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        _statusLabel(status),
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

String _dateLabel(String raw) {
  if (raw.trim().isEmpty) {
    return 'Tanggal belum tersedia';
  }
  final date = DateTime.tryParse(raw.trim().replaceFirst(' ', 'T'));
  if (date == null) {
    return raw;
  }
  String two(int n) => n.toString().padLeft(2, '0');
  // Tampilkan jam sesuai nilai dari server. Jangan menggeser zona waktu
  // bila timestamp belum menyertakan offset zona waktu.
  final display = date.isUtc ? date.toLocal() : date;
  return '${two(display.day)}/${two(display.month)}/${display.year} '
      '• ${two(display.hour)}:${two(display.minute)}';
}

String _statusLabel(String status) {
  switch (status) {
    case 'proses':
      return 'Proses';
    case 'kirim':
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
      return status.isEmpty ? '-' : status;
  }
}

Color _statusColor(String status) {
  switch (status) {
    case 'proses':
      return const Color(0xFFA65A04);
    case 'kirim':
      return const Color(0xFF1873B4);
    case 'selesai':
      return const Color(0xFF0B8B65);
    case 'batal':
      return const Color(0xFFB42332);
    case 'affiliate':
      return const Color(0xFF6956B5);
    case 'pengembalian':
      return const Color(0xFFB45309);
    case 'pengiriman_gagal':
      return const Color(0xFFB42332);
    default:
      return Colors.grey;
  }
}

String _errorMessage(Object error) {
  if (error is DioException) {
    final status = error.response?.statusCode;
    if (status == 401) {
      return 'Sesi login sudah berakhir. Silakan masuk kembali.';
    }
    if (status == 403) {
      return 'Akun tidak memiliki izin untuk mengakses pesanan.';
    }
    if (status == 404) {
      return 'Data pesanan belum dapat dibuka. Silakan coba lagi atau hubungi admin.';
    }
    if (status == 422) {
      final body = error.response?.data;
      if (body is Map && body['message'] != null) {
        return body['message'].toString();
      }
      return 'Pencarian belum dapat diproses. Silakan coba lagi.';
    }
    if (status != null && status >= 500) {
      return 'Layanan sedang mengalami kendala. Silakan coba kembali.';
    }
    return 'Koneksi terganggu. Periksa internet lalu coba kembali.';
  }
  if (error is FormatException || error is StateError) {
    return error.toString().replaceFirst(
      RegExp(r'^(FormatException|Bad state): '),
      '',
    );
  }
  return 'Pesanan belum dapat dimuat. Silakan coba kembali.';
}

String _asText(dynamic value, {String fallback = ''}) =>
    value == null ? fallback : value.toString();

String _rupiah(num amount) =>
    'Rp${amount.toStringAsFixed(0).replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+(?!\d))'), (m) => '${m[1]}.')}';
