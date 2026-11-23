import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../app/app_theme.dart';
import '../../../core/network/api_client.dart';
import '../../orders/services/cs_order_updates.dart';
import '../../chat/pages/chat_order_launcher.dart';

class CsOrdersPage extends StatefulWidget {
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
  final searchController = TextEditingController();
  final _storage = const FlutterSecureStorage();
  Timer? _searchTimer;
  Timer? _refreshTimer;
  bool _appResumed = true;
  String selectedStatus = 'semua';
  List<_CsOrder> orders = [];
  bool loading = true;
  String? error;
  int _requestId = 0;

  static const statuses = [
    'semua',
    'proses',
    'kirim',
    'selesai',
    'batal',
    'affiliate',
    'pengembalian',
    'pengiriman_gagal',
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadOrders();
    CsOrderUpdates.version.addListener(_onOrderCreated);
    _startRefreshTimer();
  }

  void _startRefreshTimer() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted && widget.isActive && _appResumed && !loading) {
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
    final resumed = state == AppLifecycleState.resumed;
    _appResumed = resumed;
    if (resumed && widget.isActive) {
      _loadOrders(silent: true);
    }
  }

  void _onOrderCreated() {
    if (mounted) _loadOrders();
  }

  @override
  void dispose() {
    _searchTimer?.cancel();
    _refreshTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    CsOrderUpdates.version.removeListener(_onOrderCreated);
    searchController.dispose();
    super.dispose();
  }

  Future<String> _token() async {
    final token = await _storage.read(key: 'auth_token');
    if (token == null || token.isEmpty) {
      throw StateError('Sesi login tidak ditemukan. Silakan login kembali.');
    }
    return token;
  }

  Future<void> _loadOrders({bool silent = false}) async {
    final currentRequest = ++_requestId;
    if (mounted) {
      setState(() {
        if (!silent) loading = true;
        error = null;
      });
    }

    try {
      final token = await _token();
      final response = await ApiClient.dio.get<dynamic>(
        '/pesanan',
        queryParameters: {
          if (searchController.text.trim().isNotEmpty)
            'search': searchController.text.trim(),
          if (selectedStatus != 'semua') 'status': selectedStatus,
        },
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      final body = response.data;
      if (body is! Map || body['success'] != true || body['data'] is! List) {
        throw const FormatException('Format daftar pesanan dari API tidak sesuai.');
      }
      final parsed = (body['data'] as List)
          .whereType<Map>()
          .map((item) => _CsOrder.fromJson(Map<String, dynamic>.from(item)))
          .toList();
      if (!mounted || currentRequest != _requestId) return;
      setState(() { orders = parsed; loading = false; });
    } catch (e) {
      if (!mounted || currentRequest != _requestId) return;
      setState(() {
        loading = false;
        orders = [];
        error = _errorMessage(e);
      });
    }
  }

  void _onSearchChanged(String _) {
    setState(() {});
    _searchTimer?.cancel();
    _searchTimer = Timer(const Duration(milliseconds: 450), _loadOrders);
  }

  void _changeStatus(String? value) {
    if (value == null) return;
    _searchTimer?.cancel();
    setState(() { selectedStatus = value; });
    _loadOrders();
  }

  Future<void> _showOrderDetail(_CsOrder order) async {
    // Endpoint detail diminta hanya saat kartu dibuka; data sensitif tidak
    // diambil massal saat pengguna melihat daftar.
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => _OrderDetailSheet(order: order, storage: _storage),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(18, 20, 18, 22),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF103961), Color(0xFF145B91)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.vertical(bottom: Radius.circular(24)),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Pesanan Saya', style: TextStyle(
                  color: Colors.white, fontSize: 23, fontWeight: FontWeight.bold,
                )),
                SizedBox(height: 6),
                Text('Lihat dan kelola pesanan Meta milikmu',
                  style: TextStyle(color: Color(0xFFD2E5F7), fontSize: 12)),
              ],
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _loadOrders,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(15),
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: widget.onAddOrder,
                      icon: const Icon(Icons.add_circle_outline),
                      label: const Text('Tambah Pesanan'),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: searchController,
                    onChanged: _onSearchChanged,
                    decoration: InputDecoration(
                      hintText: 'Cari nomor pesanan / nama / nomor resi...',
                      hintStyle: const TextStyle(fontSize: 13),
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: searchController.text.isEmpty ? null : IconButton(
                        tooltip: 'Hapus pencarian',
                        icon: const Icon(Icons.close),
                        onPressed: () {
                          searchController.clear();
                          _searchTimer?.cancel();
                          setState(() {});
                          _loadOrders();
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: selectedStatus,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Filter Status',
                      prefixIcon: Icon(Icons.filter_list),
                    ),
                    items: statuses.map((status) => DropdownMenuItem(
                      value: status,
                      child: Text(status == 'semua' ? 'Semua Status' : _statusLabel(status)),
                    )).toList(),
                    onChanged: _changeStatus,
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: loading ? null : _loadOrders,
                      icon: const Icon(Icons.refresh, size: 19),
                      label: const Text('Muat Ulang'),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Daftar Pesanan', style: TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.navy,
                      )),
                      Text(loading ? 'Memuat...' : '${orders.length} pesanan',
                        style: const TextStyle(fontSize: 12, color: Colors.black54)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (loading)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 40),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (error != null)
                    _MessagePanel(
                      icon: Icons.wifi_off_outlined,
                      title: 'Gagal memuat pesanan',
                      description: error!,
                      onRetry: _loadOrders,
                    )
                  else if (orders.isEmpty)
                    const _MessagePanel(
                      icon: Icons.search_off_outlined,
                      title: 'Pesanan tidak ditemukan',
                      description: 'Coba ubah kata pencarian atau filter status.',
                    )
                  else
                    ...orders.map((order) => Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _OrderCard(order: order, onTap: () => _showOrderDetail(order)),
                    )),
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
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(15),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFE5EBF2)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Expanded(child: Text(order.number, style: const TextStyle(
                  color: AppTheme.navy, fontWeight: FontWeight.bold, fontSize: 14,
                ))),
                _StatusBadge(status: order.status),
              ]),
              const SizedBox(height: 11),
              Text(order.buyer, style: const TextStyle(
                fontSize: 14, fontWeight: FontWeight.w600,
              )),
              if (order.resi.isNotEmpty) ...[
                const SizedBox(height: 5),
                Text('Resi: ${order.resi}', style: const TextStyle(
                  fontSize: 12, color: Color(0xFF61758A),
                )),
              ],
              const SizedBox(height: 13),
              const Divider(height: 1),
              const SizedBox(height: 12),
              Row(children: [
                const Icon(Icons.calendar_today_outlined, size: 14, color: Colors.grey),
                const SizedBox(width: 6),
                Expanded(child: Text(_dateLabel(order.date), style: const TextStyle(
                  fontSize: 11, color: Colors.black54,
                ))),
                Text(_rupiah(order.totalPrice), style: const TextStyle(
                  fontWeight: FontWeight.bold, color: AppTheme.navy, fontSize: 14,
                )),
              ]),
              const SizedBox(height: 11),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                Text('Lihat Detail', style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.primary,
                )),
                const SizedBox(width: 4),
                const Icon(Icons.chevron_right, size: 17, color: AppTheme.primary),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}

class _OrderDetailSheet extends StatefulWidget {
  final _CsOrder order;
  final FlutterSecureStorage storage;

  const _OrderDetailSheet({required this.order, required this.storage});

  @override
  State<_OrderDetailSheet> createState() => _OrderDetailSheetState();
}

class _OrderDetailSheetState extends State<_OrderDetailSheet> {
  Map<String, dynamic>? detail;
  bool loading = true;
  String? error;

  @override
  void initState() {
    super.initState();
    _loadDetail();
  }

  Future<void> _loadDetail() async {
    setState(() { loading = true; error = null; });
    try {
      final token = await widget.storage.read(key: 'auth_token');
      if (token == null || token.isEmpty) {
        throw StateError('Sesi login tidak ditemukan. Silakan login kembali.');
      }
      final response = await ApiClient.dio.get<dynamic>(
        '/pesanan/detail/${Uri.encodeComponent(widget.order.number)}',
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      final body = response.data;
      if (body is! Map || body['success'] != true || body['data'] is! Map) {
        throw const FormatException('Format detail pesanan dari API belum sesuai.');
      }
      if (!mounted) return;
      setState(() {
        detail = Map<String, dynamic>.from(body['data'] as Map);
        loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() { loading = false; error = _errorMessage(e); });
    }
  }

  @override
  Widget build(BuildContext context) {
    final order = widget.order;
    final data = detail;
    final pembeli = _asMap(data?['informasiPembeli']);
    final alamat = _asMap(pembeli['address']);
    final pesanan = _asMap(data?['pesanan']);
    final produkList = _asListOfMaps(data?['informasiProduk']);
    final pembayaranList = _asListOfMaps(data?['pembayaran']);
    final pembayaran = pembayaranList.isEmpty
        ? <String, dynamic>{}
        : pembayaranList.first;

    final bagianAlamat = [
      _asText(alamat['desa']),
      _asText(alamat['kecamatan']),
      _asText(alamat['kabupatenKota']),
      _asText(alamat['provinsi']),
    ].where((item) => item.trim().isNotEmpty).toList();
    final kodePos = _asText(alamat['kodePos']);
    final alamatLengkap = [
      _asText(alamat['alamatLengkap']),
      ...bagianAlamat,
      if (kodePos.isNotEmpty) kodePos,
    ].join(', ');
    final totalHarga = _asNumber(pesanan['totalHarga'], fallback: order.totalPrice);
    final catatanPesanan = _asText(pesanan['catatanPesanan']);
    final jenisTransaksi = _asText(pembayaran['jenis_transaksi']).toUpperCase();

    return SafeArea(
      top: false,
      child: FractionallySizedBox(
        heightFactor: 0.85,
        child: Column(children: [
          const SizedBox(height: 12),
          Container(width: 42, height: 5, decoration: BoxDecoration(
            color: const Color(0xFFD6E0EA), borderRadius: BorderRadius.circular(8),
          )),
          const SizedBox(height: 18),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20),
            child: Align(alignment: Alignment.centerLeft, child: Text('Detail Pesanan',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: AppTheme.navy))),
          ),
          const Divider(height: 25),
          Expanded(child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            children: [
              Row(children: [
                Expanded(child: Text(order.number, style: const TextStyle(
                  fontSize: 18, fontWeight: FontWeight.bold,
                ))),
                _StatusBadge(status: order.status),
              ]),
              const SizedBox(height: 8),
              Text('Tanggal input: ${_dateLabel(order.date)}',
                style: const TextStyle(color: Colors.black54)),
              const SizedBox(height: 18),
              if (loading)
                const Center(child: Padding(
                  padding: EdgeInsets.all(30), child: CircularProgressIndicator(),
                ))
              else if (error != null)
                _MessagePanel(
                  icon: Icons.error_outline,
                  title: 'Detail belum dapat dimuat',
                  description: error!,
                  onRetry: _loadDetail,
                )
              else if (data != null) ...[
                const _SectionTitle('Informasi Pembeli'),
                _DetailRow('Nama', _asText(pembeli['namaPembeli'], fallback: order.buyer)),
                _DetailRow('No. HP', _asText(pembeli['phone'])),
                _DetailRow('Alamat', alamatLengkap),
                if (order.resi.isNotEmpty) _DetailRow('No. Resi', order.resi),
                const SizedBox(height: 20),
                const _SectionTitle('Informasi Produk'),
                if (produkList.isEmpty)
                  const Text('Tidak ada informasi produk.',
                    style: TextStyle(fontSize: 12, color: Colors.black54))
                else
                  ...produkList.asMap().entries.map((entry) {
                    final index = entry.key;
                    final item = entry.value;
                    final master = _asMap(item['produk']);
                    final namaProduk = _asText(master['nama_produk'],
                      fallback: _asText(master['namaProduk']));
                    final variasi = _asText(master['variasi']);
                    final fotoUrls = _asListOfMaps(item['reqfoto'])
                        .map((f) => _asText(f['foto']).trim())
                        .where((url) => url.isNotEmpty)
                        .toList();
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 15),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('Produk ${index + 1}', style: const TextStyle(
                          color: AppTheme.navy, fontWeight: FontWeight.bold,
                        )),
                        if (namaProduk.isNotEmpty) _DetailRow('Nama Produk', namaProduk),
                        _DetailRow('SKU', _asText(item['sku'])),
                        if (variasi.isNotEmpty) _DetailRow('Variasi', variasi),
                        _DetailRow('Jumlah', '${_asText(item['jumlah'], fallback: '0')} pcs'),
                        if (_asText(item['catatan']).isNotEmpty)
                          _DetailRow('Catatan', _asText(item['catatan'])),
                        if (fotoUrls.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Text('Foto Request (${fotoUrls.length})',
                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                          const SizedBox(height: 9),
                          Wrap(
                            spacing: 9,
                            runSpacing: 9,
                            children: fotoUrls.map((url) => _OrderPhoto(
                              key: ValueKey(url),
                              url: url,
                              storage: widget.storage,
                              title: 'Foto Request • Produk ${index + 1}',
                            )).toList(),
                          ),
                        ],
                      ]),
                    );
                  }),
                const SizedBox(height: 5),
                const _SectionTitle('Pembayaran'),
                _DetailRow('Metode', jenisTransaksi),
                _DetailRow('COD', _rupiah(_asNumber(pembayaran['cod']))),
                _DetailRow('NON-COD', _rupiah(_asNumber(pembayaran['non_cod']))),
                _DetailRow('DP', _rupiah(_asNumber(pembayaran['dp']))),
                _DetailRow('Total Harga', _rupiah(totalHarga)),
                if (_asText(pembayaran['bukti_bayar']).trim().isNotEmpty) ...[
                  const SizedBox(height: 12),
                  const Text('Bukti Transfer',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 9),
                  _OrderPhoto(
                    url: _asText(pembayaran['bukti_bayar']).trim(),
                    storage: widget.storage,
                    title: 'Bukti Transfer',
                  ),
                ],
                if (catatanPesanan.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  const _SectionTitle('Catatan Pesanan'),
                  Text(catatanPesanan),
                ],
              ],
            ],
          )),
          Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
          child: Column(
            children: [
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => ChatOrderLauncher.open(
                    context,
                    noPesanan: order.number,
                  ),
                  icon: const Icon(Icons.chat_bubble_outline),
                  label: const Text('Chat Klarifikasi'),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Tutup Detail'),
                ),
              ),
            ],
          ),
        ),
        ]),
      ),
    );
  }

}

/// Menampilkan foto dari URL FileGator. Token hanya disertakan bila origin
/// URL sama dengan origin API yang telah dikonfigurasi aplikasi.
class _OrderPhoto extends StatefulWidget {
  final String url;
  final String title;
  final FlutterSecureStorage storage;

  const _OrderPhoto({
    super.key,
    required this.url,
    required this.title,
    required this.storage,
  });

  @override
  State<_OrderPhoto> createState() => _OrderPhotoState();
}

class _OrderPhotoState extends State<_OrderPhoto> {
  late Future<Uint8List> _imageFuture;

  @override
  void initState() {
    super.initState();
    _imageFuture = _loadImage();
  }

  @override
  void didUpdateWidget(covariant _OrderPhoto oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _imageFuture = _loadImage();
    }
  }

  Future<Uint8List> _loadImage() async {
    final uri = Uri.tryParse(widget.url);
    if (uri == null || !uri.hasAuthority ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw const FormatException('URL gambar tidak valid.');
    }

    final configuredApi = Uri.parse(ApiClient.dio.options.baseUrl);
    final sameOrigin = uri.scheme == configuredApi.scheme &&
        uri.host == configuredApi.host && uri.port == configuredApi.port;
    final headers = <String, String>{'Accept': 'image/*'};
    if (sameOrigin) {
      final token = await widget.storage.read(key: 'auth_token');
      if (token != null && token.isNotEmpty) {
        headers['Authorization'] = 'Bearer $token';
      }
    }

    final response = await ApiClient.dio.get<List<int>>(
      widget.url,
      options: Options(responseType: ResponseType.bytes, headers: headers),
    );
    final bytes = response.data;
    if (bytes == null || bytes.isEmpty) {
      throw const FormatException('File gambar kosong.');
    }
    return Uint8List.fromList(bytes);
  }

  void _retry() {
    setState(() => _imageFuture = _loadImage());
  }

  void _openPreview(Uint8List bytes) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        insetPadding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 4, 0),
              child: Row(children: [
                Expanded(child: Text(widget.title,
                  style: const TextStyle(fontWeight: FontWeight.bold))),
                IconButton(
                  tooltip: 'Tutup',
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(dialogContext),
                ),
              ]),
            ),
            Flexible(
              child: InteractiveViewer(
                minScale: 0.7,
                maxScale: 5,
                child: Image.memory(bytes, fit: BoxFit.contain),
              ),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // File PDF tidak bisa ditampilkan oleh Image.memory.
    final path = Uri.tryParse(widget.url)?.queryParameters['path'] ?? widget.url;
    if (path.toLowerCase().endsWith('.pdf')) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFFF4F7FA),
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.picture_as_pdf_outlined),
          SizedBox(width: 8),
          Text('Bukti bayar PDF tersedia (tanpa pratinjau gambar)'),
        ]),
      );
    }

    return FutureBuilder<Uint8List>(
      future: _imageFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const SizedBox(
            width: 110,
            height: 110,
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }
        if (snapshot.hasError || !snapshot.hasData) {
          return InkWell(
            onTap: _retry,
            borderRadius: BorderRadius.circular(10),
            child: Container(
              width: 110,
              height: 110,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                color: const Color(0xFFF4F7FA),
              ),
              child: const Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.broken_image_outlined, color: Colors.grey),
                  SizedBox(height: 6),
                  Text('Gagal memuat\nKetuk ulang',
                    style: TextStyle(fontSize: 11), textAlign: TextAlign.center),
                ],
              ),
            ),
          );
        }
        final bytes = snapshot.data!;
        return InkWell(
          onTap: () => _openPreview(bytes),
          borderRadius: BorderRadius.circular(10),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.memory(
              bytes,
              width: 110,
              height: 110,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) => const SizedBox(
                width: 110,
                height: 110,
                child: Center(child: Icon(Icons.broken_image_outlined)),
              ),
            ),
          ),
        );
      },
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
      child: Column(children: [
        Icon(icon, size: 44, color: Colors.grey),
        const SizedBox(height: 12),
        Text(title, style: const TextStyle(fontWeight: FontWeight.bold), textAlign: TextAlign.center),
        const SizedBox(height: 6),
        Text(description, textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.black54, fontSize: 12)),
        if (onRetry != null) ...[
          const SizedBox(height: 12),
          TextButton.icon(
            onPressed: () { onRetry!(); },
            icon: const Icon(Icons.refresh),
            label: const Text('Coba Lagi'),
          ),
        ],
      ]),
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
      child: Text(_statusLabel(status), style: TextStyle(
        color: color, fontSize: 11, fontWeight: FontWeight.bold,
      )),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;
  const _SectionTitle(this.title);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(title, style: const TextStyle(
      fontSize: 15, fontWeight: FontWeight.bold, color: AppTheme.navy,
    )),
  );
}

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;
  const _DetailRow(this.label, this.value);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 7),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(width: 110, child: Text(label, style: const TextStyle(
        fontSize: 12, color: Colors.black54,
      ))),
      Expanded(child: Text(value.isEmpty ? '-' : value,
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
    ]),
  );
}

Map<String, dynamic> _asMap(dynamic value) =>
    value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

List<Map<String, dynamic>> _asListOfMaps(dynamic value) =>
    value is List ? value.whereType<Map>().map((item) => Map<String, dynamic>.from(item)).toList() : [];

num _asNumber(dynamic value, {num fallback = 0}) =>
    value is num ? value : num.tryParse('${value ?? ''}') ?? fallback;

String _asText(dynamic value, {String fallback = ''}) =>
    value == null ? fallback : value.toString();

String _rupiah(num amount) =>
    'Rp${amount.toStringAsFixed(0).replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+(?!\d))'), (m) => '${m[1]}.')}';

String _dateLabel(String raw) {
  if (raw.isEmpty) return '-';
  final date = DateTime.tryParse(raw.replaceFirst(' ', 'T'));
  if (date == null) return raw;
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(date.day)}/${two(date.month)}/${date.year}';
}

String _statusLabel(String status) {
  switch (status) {
    case 'proses': return 'Proses';
    case 'kirim': return 'Dikirim';
    case 'selesai': return 'Selesai';
    case 'batal': return 'Batal';
    case 'affiliate': return 'Affiliate';
    case 'pengembalian': return 'Pengembalian';
    case 'pengiriman_gagal': return 'Pengiriman Gagal';
    default: return status.isEmpty ? '-' : status;
  }
}

Color _statusColor(String status) {
  switch (status) {
    case 'proses': return const Color(0xFFA65A04);
    case 'kirim': return const Color(0xFF1873B4);
    case 'selesai': return const Color(0xFF0B8B65);
    case 'batal': return const Color(0xFFB42332);
    case 'affiliate': return const Color(0xFF6956B5);
    case 'pengembalian': return const Color(0xFFB45309);
    case 'pengiriman_gagal': return const Color(0xFFB42332);
    default: return Colors.grey;
  }
}

String _errorMessage(Object error) {
  if (error is DioException) {
    final status = error.response?.statusCode;
    if (status == 401) return 'Token login tidak valid atau sudah berakhir. Silakan login kembali.';
    if (status == 403) return 'Akun tidak memiliki izin untuk mengakses pesanan.';
    if (status == 404) return 'Endpoint API tidak ditemukan. Periksa route Laravel.';
    if (status == 422) {
      final body = error.response?.data;
      if (body is Map && body['message'] != null) return body['message'].toString();
      return 'Parameter pencarian atau filter tidak valid.';
    }
    if (status != null && status >= 500) return 'Server Laravel mengalami kesalahan (HTTP $status).';
    return 'Tidak dapat terhubung ke server Laravel. Periksa jaringan dan IP API.';
  }
  if (error is FormatException || error is StateError) return error.toString().replaceFirst(RegExp(r'^(FormatException|Bad state): '), '');
  return 'Terjadi kesalahan saat mengambil pesanan: $error';
}