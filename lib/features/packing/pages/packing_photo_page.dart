import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:image_picker/image_picker.dart';

import '../../../app/app_theme.dart';
import '../../../core/network/api_client.dart';
import '../../chat/pages/chat_order_launcher.dart';

/// Foto Packing Meta.
/// GET /api/packing/antrian
/// GET /api/packing/detail/{no_pesanan}
/// POST /api/packing/foto_meta (multipart: no_pesanan dan foto[id_per_produk])
class PackingPhotoPage extends StatefulWidget {
  const PackingPhotoPage({super.key});

  @override
  State<PackingPhotoPage> createState() => _PackingPhotoPageState();
}

class _PackingPhotoPageState extends State<PackingPhotoPage> {
  static const _storage = FlutterSecureStorage();
  final _searchController = TextEditingController();
  final List<Map<String, dynamic>> _orders = [];
  Timer? _searchTimer;
  String? _token;
  String? _platform;
  DateTime? _batasKirim;
  String? _error;
  bool _loading = true;
  int _requestSequence = 0;

  static Map<String, dynamic> _map(Object? value) =>
      value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

  static String _text(Object? value, {String fallback = '-'}) {
    final output = value?.toString().trim() ?? '';
    return output.isEmpty ? fallback : output;
  }

  static String _date(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  // Respons Laravel dapat berupa ISO 8601 UTC (akhiran Z) atau waktu lokal.
  // Waktu dengan zona dikonversi mengikuti zona waktu perangkat.
  static String _formatTanggal(Object? value) {
    final raw = value?.toString().trim() ?? '';
    if (raw.isEmpty) return '-';
    try {
      final date = DateTime.parse(raw).toLocal();
      String two(int value) => value.toString().padLeft(2, '0');
      return '${date.year}-${two(date.month)}-${two(date.day)} '
          '${two(date.hour)}:${two(date.minute)}:${two(date.second)}';
    } catch (_) {
      return raw;
    }
  }

  static String _apiError(Object error) {
    if (error is DioException) {
      final body = _map(error.response?.data);
      final message = body['message']?.toString();
      final validation = body['errors'];
      if (validation is Map) {
        final details = validation.values
            .whereType<List>()
            .expand((messages) => messages)
            .map((item) => item.toString())
            .where((item) => item.isNotEmpty)
            .toSet()
            .join(' ');
        if (details.isNotEmpty) {
          return '${message ?? 'Validasi gagal.'} $details';
        }
      }
      if (message != null && message.isNotEmpty) return message;
      if (error.response?.statusCode == 401) {
        return 'Sesi login tidak valid. Silakan login kembali.';
      }
      return 'Request gagal (HTTP ${error.response?.statusCode ?? '-'}).';
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
    _initialize();
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
      if (_platform == 'marketplace') {
        setState(() => _loading = false);
        return;
      }
      await _loadOrders();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = _apiError(error);
        _loading = false;
      });
    }
  }

  Future<void> _loadOrders() async {
    if (_token == null || _platform == 'marketplace') return;
    final request = ++_requestSequence;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final query = _searchController.text.trim();
      final response = await ApiClient.dio.get<dynamic>(
        '/packing/antrian',
        queryParameters: {
          if (query.isNotEmpty) 'search': query,
          if (_batasKirim != null) 'batas_kirim': _date(_batasKirim!),
        },
        options: _authOptions,
      );
      final payload = _map(response.data);
      if (payload['success'] != true) {
        throw Exception(_text(payload['message'], fallback: 'Gagal memuat antrean.'));
      }
      final raw = payload['data'];
      if (raw is! List) {
        throw Exception('Format daftar antrean tidak sesuai respons API.');
      }
      if (!mounted || request != _requestSequence) return;
      setState(() {
        _orders
          ..clear()
          ..addAll(raw.map(_map));
      });
    } catch (error) {
      if (!mounted || request != _requestSequence) return;
      setState(() {
        _orders.clear();
        _error = _apiError(error);
      });
    } finally {
      if (mounted && request == _requestSequence) {
        setState(() => _loading = false);
      }
    }
  }

  void _onSearchChanged(String _) {
    _searchTimer?.cancel();
    _searchTimer = Timer(const Duration(milliseconds: 450), _loadOrders);
  }

  Future<void> _chooseDeadline() async {
    final now = DateTime.now();
    final chosen = await showDatePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(now.year + 5),
      initialDate: _batasKirim ?? now,
    );
    if (!mounted || chosen == null) return;
    setState(() => _batasKirim = chosen);
    await _loadOrders();
  }

  Future<void> _openOrder(String noPesanan) async {
    if (_token == null || noPesanan.isEmpty) return;
    final uploaded = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => PackingPhotoDetailPage(
          noPesanan: noPesanan,
          token: _token!,
        ),
      ),
    );
    if (mounted && uploaded == true) await _loadOrders();
  }

  Widget _orderCard(Map<String, dynamic> item) {
    final noPesanan = _text(item['no_pesanan']);
    final resi = _text(item['no_resi'], fallback: 'Belum ada');
    final buyer = _text(item['nama_pembeli']);
    final deadline = _formatTanggal(item['batas_kirim_at']);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      color: Colors.white,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _openOrder(noPesanan),
        child: Padding(
          padding: const EdgeInsets.all(15),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Expanded(child: Text(noPesanan,
                    style: const TextStyle(fontWeight: FontWeight.bold,
                        color: AppTheme.navy, fontSize: 14))),
                const Icon(Icons.chevron_right, color: AppTheme.primary),
              ]),
              const SizedBox(height: 8),
              Text(buyer, style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Text('Resi: $resi', style: const TextStyle(fontSize: 12)),
              const SizedBox(height: 5),
              Text('Batas kirim: $deadline',
                  style: const TextStyle(color: Color(0xFF61758A), fontSize: 12)),
              const SizedBox(height: 7),
              const Text('Menunggu foto barang',
                  style: TextStyle(color: Color(0xFFA65A04), fontSize: 12)),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _searchTimer?.cancel();
    _requestSequence++;
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(18, 20, 18, 24),
          decoration: const BoxDecoration(
            gradient: LinearGradient(colors: [Color(0xFF103961), Color(0xFF145B91)]),
            borderRadius: BorderRadius.vertical(bottom: Radius.circular(24)),
          ),
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Foto Packing Meta', style: TextStyle(fontSize: 23,
                  fontWeight: FontWeight.bold, color: Colors.white)),
              SizedBox(height: 6),
              Text('Foto barang sebelum dipacking',
                  style: TextStyle(color: Color(0xFFD2E5F7), fontSize: 12)),
            ],
          ),
        ),
        if (_platform == 'marketplace')
          const Expanded(child: Center(child: Padding(
            padding: EdgeInsets.all(24),
            child: Text('Menu Foto Meta hanya tersedia untuk akun Packing Meta.',
                textAlign: TextAlign.center),
          )))
        else ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(15, 15, 15, 0),
            child: Column(children: [
              TextField(
                controller: _searchController,
                onChanged: _onSearchChanged,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) {
                  _searchTimer?.cancel();
                  _loadOrders();
                },
                decoration: InputDecoration(
                  labelText: 'Cari nomor pesanan, resi, atau pembeli',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: IconButton(
                    tooltip: 'Cari',
                    icon: const Icon(Icons.arrow_forward),
                    onPressed: _loadOrders,
                  ),
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(child: OutlinedButton.icon(
                  onPressed: _chooseDeadline,
                  icon: const Icon(Icons.calendar_today_outlined, size: 18),
                  label: Text(_batasKirim == null
                      ? 'Filter batas kirim' : _date(_batasKirim!)),
                )),
                if (_batasKirim != null) IconButton(
                  tooltip: 'Hapus filter tanggal',
                  onPressed: () {
                    setState(() => _batasKirim = null);
                    _loadOrders();
                  },
                  icon: const Icon(Icons.close),
                ),
                IconButton(
                  tooltip: 'Muat ulang',
                  onPressed: _loading ? null : _loadOrders,
                  icon: const Icon(Icons.refresh),
                ),
              ]),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(15, 12, 15, 8),
            child: Row(children: [
              const Expanded(child: Text('Antrean Foto Meta',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17,
                      color: AppTheme.navy))),
              Text('${_orders.length} pesanan',
                  style: const TextStyle(fontSize: 12, color: Colors.black54)),
            ]),
          ),
          Expanded(child: RefreshIndicator(
            onRefresh: _loadOrders,
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(15),
                    children: [
                      if (_error != null) ...[
                        Text(_error!, style: const TextStyle(color: Colors.red)),
                        const SizedBox(height: 12),
                        OutlinedButton(onPressed: _loadOrders,
                            child: const Text('Coba Lagi')),
                        const SizedBox(height: 12),
                      ],
                      if (_orders.isEmpty && _error == null)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 60),
                          child: Center(child: Text('Tidak ada pesanan yang menunggu foto.')),
                        ),
                      for (final order in _orders) _orderCard(order),
                    ],
                  ),
          )),
        ],
      ]),
    );
  }
}

class PackingPhotoDetailPage extends StatefulWidget {
  const PackingPhotoDetailPage({
    super.key,
    required this.noPesanan,
    required this.token,
  });

  final String noPesanan;
  final String token;

  @override
  State<PackingPhotoDetailPage> createState() => _PackingPhotoDetailPageState();
}

class _PackingPhotoDetailPageState extends State<PackingPhotoDetailPage> {
  final _picker = ImagePicker();
  final Map<String, XFile> _photosByProduct = {};
  Map<String, dynamic>? _detail;
  String? _error;
  bool _loading = true;
  bool _uploading = false;

  static Map<String, dynamic> _map(Object? value) =>
      value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};
  static String _text(Object? value, {String fallback = '-'}) {
    final result = value?.toString().trim() ?? '';
    return result.isEmpty ? fallback : result;
  }
  static String _apiError(Object error) {
    if (error is DioException) {
      final payload = _map(error.response?.data);
      final msg = payload['message']?.toString();
      final validation = payload['errors'];
      if (validation is Map) {
        final details = validation.values
            .whereType<List>()
            .expand((messages) => messages)
            .map((item) => item.toString())
            .where((item) => item.isNotEmpty)
            .toSet()
            .join(' ');
        if (details.isNotEmpty) return '${msg ?? 'Validasi gagal.'} $details';
      }
      if (msg != null && msg.isNotEmpty) return msg;
      return 'Request gagal (HTTP ${error.response?.statusCode ?? '-'}).';
    }
    return error.toString().replaceFirst('Exception: ', '');
  }

  Options get _authOptions => Options(headers: {
        'Authorization': 'Bearer ${widget.token}',
        'Accept': 'application/json',
      });

  @override
  void initState() {
    super.initState();
    _loadDetail();
  }

  Future<void> _loadDetail() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final response = await ApiClient.dio.get<dynamic>(
        '/packing/detail/${Uri.encodeComponent(widget.noPesanan)}',
        options: _authOptions,
      );
      final payload = _map(response.data);
      if (payload['success'] != true) {
        throw Exception(_text(payload['message'], fallback: 'Gagal memuat detail.'));
      }
      final data = _map(payload['data']);
      if (!mounted) return;
      setState(() => _detail = data);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = _apiError(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  List<Map<String, dynamic>> get _productItems {
    final raw = _detail?['informasiProduk'];
    if (raw is! List) return [];
    return raw.map(_map).toList();
  }

  String _productId(Map<String, dynamic> item) =>
      _text(item['id_per_produk'], fallback: '');

  String _productName(Map<String, dynamic> item) {
    final product = _map(item['produk']);
    final name = _text(product['nama_produk'], fallback: '');
    return name.isNotEmpty ? name : _text(item['sku'], fallback: 'Produk');
  }

  bool get _allPhotosReady {
    final items = _productItems;
    if (items.isEmpty) return false;
    final ids = items.map(_productId).toList();
    return ids.every((id) => id.isNotEmpty && _photosByProduct.containsKey(id))
        && ids.toSet().length == ids.length;
  }

  Future<void> _choosePhotoForProduct(
    Map<String, dynamic> item,
    ImageSource source,
  ) async {
    if (_uploading) return;
    final id = _productId(item);
    if (id.isEmpty) {
      _message('ID per produk tidak ditemukan. Tidak dapat memilih foto.');
      return;
    }
    try {
      final photo = await _picker.pickImage(
        source: source,
        imageQuality: 85,
      );
      if (!mounted || photo == null) return;
      setState(() => _photosByProduct[id] = photo);
    } catch (error) {
      _message('Gagal memilih foto: $error');
    }
  }

  Future<void> _uploadPhotos() async {
    if (_uploading || _detail == null) return;
    final items = _productItems;
    if (items.isEmpty) {
      _message('Rincian produk tidak ditemukan.');
      return;
    }
    if (!_allPhotosReady) {
      _message('Wajib memilih tepat 1 foto untuk setiap produk.');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Upload Foto Pesanan Jadi?'),
        content: Text(
          'Unggah ${items.length} foto untuk ${items.length} produk '
          'pesanan ${widget.noPesanan}?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Ya, Upload'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    setState(() => _uploading = true);
    try {
      final form = FormData();
      form.fields.add(MapEntry('no_pesanan', widget.noPesanan));
      for (final item in items) {
        final id = _productId(item);
        final photo = _photosByProduct[id]!;
        form.files.add(MapEntry(
          'foto[$id]',
          await MultipartFile.fromFile(photo.path, filename: photo.name),
        ));
      }
      final response = await ApiClient.dio.post<dynamic>(
        '/packing/foto_meta',
        data: form,
        options: _authOptions,
      );
      final payload = _map(response.data);
      // Sebagian controller Laravel menggunakan 'success'; sebagian hanya
      // mengembalikan status HTTP. HTTP 2xx tetap wajib.
      if (payload['success'] == false) {
        throw Exception(_text(payload['message'], fallback: 'Upload foto gagal.'));
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Foto seluruh produk berhasil diunggah.')),
      );
      Navigator.pop(context, true);
    } catch (error) {
      _message(_apiError(error));
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Widget _productPhotoPicker(Map<String, dynamic> item) {
    final id = _productId(item);
    final photo = _photosByProduct[id];
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F9FC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5EBF2)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(_productName(item),
            style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text('ID: ${id.isEmpty ? "Tidak tersedia" : id} • '
            'SKU: ${_text(item['sku'])} • '
            'Jumlah: ${_text(item['jumlah'])}',
            style: const TextStyle(fontSize: 11, color: Colors.black54)),
        const SizedBox(height: 9),
        if (photo != null) ...[
          Stack(children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.file(File(photo.path), width: 120, height: 120,
                  fit: BoxFit.cover),
            ),
            if (!_uploading)
              Positioned(right: 0, top: 0,
                  child: IconButton.filledTonal(
                    tooltip: 'Hapus foto produk',
                    onPressed: () => setState(() => _photosByProduct.remove(id)),
                    icon: const Icon(Icons.close, size: 16),
                  )),
          ]),
          const SizedBox(height: 7),
          const Text('Foto dipilih',
              style: TextStyle(color: Color(0xFF0B8B65), fontSize: 11)),
        ] else
          const Text('Belum ada foto • wajib 1 foto',
              style: TextStyle(color: Color(0xFFA65A04), fontSize: 11)),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 6, children: [
          OutlinedButton.icon(
            onPressed: _uploading || id.isEmpty ? null :
                () => _choosePhotoForProduct(item, ImageSource.camera),
            icon: const Icon(Icons.camera_alt_outlined, size: 17),
            label: const Text('Kamera'),
          ),
          OutlinedButton.icon(
            onPressed: _uploading || id.isEmpty ? null :
                () => _choosePhotoForProduct(item, ImageSource.gallery),
            icon: const Icon(Icons.photo_library_outlined, size: 17),
            label: const Text('Galeri'),
          ),
        ]),
      ]),
    );
  }

  Widget _panel(String title, Widget content) => Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFE5EBF2)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontSize: 16,
              fontWeight: FontWeight.bold, color: AppTheme.navy)),
          const SizedBox(height: 13),
          content,
        ]),
      );

  Widget _infoRow(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 110,
              child: Text(label, style: const TextStyle(color: Colors.black54,
                  fontSize: 12))),
          Expanded(child: Text(value, style: const TextStyle(
              fontSize: 12, fontWeight: FontWeight.w600))),
        ]),
      );

  String _address(Map<String, dynamic> buyer) {
    final addr = _map(buyer['address']);
    final full = _text(addr['alamatLengkap'], fallback: '');
    if (full.isNotEmpty) return full;
    return [addr['alamat'], addr['desa'], addr['kecamatan'],
      addr['kabupatenKota'], addr['provinsi'], addr['kodePos']]
        .where((v) => v != null && v.toString().trim().isNotEmpty)
        .join(', ');
  }

  Widget _buildProducts(List<dynamic> list) {
    if (list.isEmpty) return const Text('Belum ada rincian produk.');
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (final raw in list) ...[
        Builder(builder: (_) {
          final item = _map(raw);
          final product = _map(item['produk']);
          final sku = _text(item['sku']);
          final name = _text(product['nama_produk'], fallback: sku);
          final variant = _text(product['variasi'], fallback: '');
          final requestPhotos = item['reqfoto'];
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name, style: const TextStyle(fontWeight: FontWeight.bold)),
            if (variant.isNotEmpty) Text(variant, style: const TextStyle(fontSize: 12)),
            Text('SKU: $sku • Jumlah: ${_text(item['jumlah'])}',
                style: const TextStyle(fontSize: 12)),
            if (_text(item['catatan'], fallback: '').isNotEmpty)
              Text('Catatan: ${item['catatan']}',
                  style: const TextStyle(fontSize: 12)),
            if (requestPhotos is List && requestPhotos.isNotEmpty) ...[
              const SizedBox(height: 8),
              const Text('Foto request:', style: TextStyle(fontSize: 12)),
              const SizedBox(height: 5),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final photo in requestPhotos)
                  if (_text(_map(photo)['foto'], fallback: '').isNotEmpty)
                    ClipRRect(borderRadius: BorderRadius.circular(8),
                      child: Image.network(_text(_map(photo)['foto']),
                        width: 100, height: 100, fit: BoxFit.cover,
                        errorBuilder: (_, error, stackTrace) => Container(
                          width: 100, height: 100, color: const Color(0xFFE9EDF2),
                          child: const Icon(Icons.broken_image_outlined),
                        ),
                      ),
                    ),
              ]),
            ],
            const Divider(height: 24),
          ]);
        }),
      ],
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final data = _detail ?? {};
    final buyer = _map(data['informasiPembeli']);
    final order = _map(data['pesanan']);
    final rawProducts = data['informasiProduk'];
    final products = rawProducts is List ? rawProducts : <dynamic>[];
    final payments = data['pembayaran'];
    final paymentList = payments is List ? payments : <dynamic>[];

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        title: const Text('Detail Packing Meta'),
        backgroundColor: AppTheme.navy,
        foregroundColor: Colors.white,
        actions: [
          IconButton(onPressed: _loading ? null : _loadDetail,
              icon: const Icon(Icons.refresh), tooltip: 'Muat ulang'),
        ],
      ),
      body: SafeArea(child: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(_error!, textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.red)),
                    const SizedBox(height: 12),
                    OutlinedButton(onPressed: _loadDetail,
                        child: const Text('Coba Lagi')),
                  ]),
                ))
              : ListView(padding: const EdgeInsets.all(15), children: [
                  _panel('Identitas Pesanan', Column(children: [
                    _infoRow('No. Pesanan', widget.noPesanan),
                    _infoRow('Pembeli', _text(buyer['namaPembeli'])),
                    _infoRow('No. HP', _text(buyer['phone'])),
                    _infoRow('Alamat', _address(buyer)),
                    _infoRow('Resi', _text(order['noResi'])),
                    _infoRow('Platform', _text(order['platform'])),
                    _infoRow('Status', _text(order['keterangan'])),
                  ])),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _uploading
                          ? null
                          : () => ChatOrderLauncher.open(
                                context,
                                noPesanan: widget.noPesanan,
                              ),
                      icon: const Icon(Icons.chat_bubble_outline),
                      label: const Text('Chat Klarifikasi CS Meta'),
                    ),
                  ),
                  const SizedBox(height: 14),
                  _panel('Rincian Produk', _buildProducts(products)),
                  if (paymentList.isNotEmpty)
                    _panel('Informasi Pembayaran', Column(children: [
                      for (final raw in paymentList) ...[
                        Builder(builder: (_) {
                          final pay = _map(raw);
                          return Column(children: [
                            _infoRow('Jenis', _text(pay['jenis_transaksi'])),
                            _infoRow('COD', _text(pay['cod'])),
                            _infoRow('Non-COD', _text(pay['non_cod'])),
                            _infoRow('DP', _text(pay['dp'])),
                            const Divider(height: 18),
                          ]);
                        }),
                      ],
                    ])),
                  _panel('Foto Pesanan Jadi per Produk', Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Wajib 1 foto untuk setiap ID per produk. '
                        'Foto akan diunggah sesuai pasangan produknya.',
                        style: TextStyle(fontSize: 12, color: Colors.black54),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '${_photosByProduct.length}/${_productItems.length} '
                        'produk sudah dipilih fotonya',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 12),
                      for (final item in _productItems) _productPhotoPicker(item),
                      if (_productItems.isEmpty)
                        const Text('Belum ada data per produk dari API.'),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _uploading || !_allPhotosReady
                              ? null : _uploadPhotos,
                          icon: _uploading
                              ? const SizedBox(width: 18, height: 18,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: Colors.white))
                              : const Icon(Icons.cloud_upload_outlined),
                          label: Text(_uploading
                              ? 'Mengunggah...'
                              : 'Upload ${_productItems.length} Foto Produk'),
                        ),
                      ),
                    ],
                  )),
                  const SizedBox(height: 16),
                ])),
    );
  }
}
