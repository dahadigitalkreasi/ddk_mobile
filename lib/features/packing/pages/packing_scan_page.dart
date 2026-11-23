import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../app/app_theme.dart';
import '../../../core/network/api_client.dart';
import '../../chat/pages/chat_order_launcher.dart';

/// API:
/// GET   /api/packing/antrian/ready
/// GET   /api/packing/scan/{no_resi}
/// PATCH /api/packing/scan/update/{no_pesanan}
class PackingScanPage extends StatefulWidget {
  const PackingScanPage({super.key});

  @override
  State<PackingScanPage> createState() => _PackingScanPageState();
}

class _PackingScanPageState extends State<PackingScanPage>
    with WidgetsBindingObserver {
  static const _storage = FlutterSecureStorage();
  final resiController = TextEditingController();
  final List<Map<String, dynamic>> _readyOrders = [];

  Timer? _refreshTimer;
  String? _token;
  String? _platform;
  String? _readyError;
  String? lastSuccessResi;
  bool _loadingReady = true;
  bool processing = false;
  bool _cameraOpen = false;
  int _loadSequence = 0;

  static Map<String, dynamic> _map(Object? value) =>
      value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

  static String _text(Object? value, {String fallback = '-'}) {
    final valueText = value?.toString().trim() ?? '';
    return valueText.isEmpty ? fallback : valueText;
  }

  static String _errorMessage(Object error) {
    if (error is DioException) {
      final body = _map(error.response?.data);
      final message = body['message']?.toString();
      if (message != null && message.trim().isNotEmpty) return message;
      switch (error.response?.statusCode) {
        case 401:
          return 'Sesi login berakhir. Silakan masuk kembali.';
        case 403:
          return 'Akun tidak memiliki izin untuk proses ini.';
        case 404:
          return 'Data tidak ditemukan.';
        case 422:
          return 'Data tidak memenuhi syarat pengiriman.';
        default:
          return 'Permintaan gagal (HTTP ${error.response?.statusCode ?? '-'}).';
      }
    }
    return error.toString().replaceFirst('Exception: ', '');
  }

  Options get _authOptions => Options(headers: {
        'Accept': 'application/json',
        'Authorization': 'Bearer $_token',
      });

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initialize();
    _refreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted && !processing && _token != null) {
        _loadReady(silent: true);
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _token != null) {
      _loadReady(silent: true);
    }
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
      await _loadReady();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingReady = false;
        _readyError = _errorMessage(error);
      });
    }
  }

  Future<void> _loadReady({bool silent = false}) async {
    if (_token == null) return;
    final requestId = ++_loadSequence;
    if (!silent) {
      setState(() {
        _loadingReady = true;
        _readyError = null;
      });
    }
    try {
      final response = await ApiClient.dio.get<dynamic>(
        '/packing/antrian/ready',
        options: _authOptions,
      );
      final payload = _map(response.data);
      if (payload['success'] != true) {
        throw Exception(_text(payload['message'], fallback: 'Gagal memuat antrean.'));
      }
      final raw = payload['data'];
      if (raw is! List) {
        throw Exception('Format data antrean siap dikirim tidak sesuai.');
      }
      // Filter di Flutter hanya untuk tampilan; aturan akses utama tetap di API.
      final items = raw.map(_map).where((item) {
        return _platform != 'marketplace' ||
            _text(item['platform']).toLowerCase() != 'meta';
      }).toList();
      if (!mounted || requestId != _loadSequence) return;
      setState(() {
        _readyOrders
          ..clear()
          ..addAll(items);
        _readyError = null;
      });
    } catch (error) {
      if (!mounted || requestId != _loadSequence) return;
      setState(() {
        _readyOrders.clear();
        _readyError = _errorMessage(error);
      });
    } finally {
      if (mounted && requestId == _loadSequence) {
        setState(() => _loadingReady = false);
      }
    }
  }

  void message(String value) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(value), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> processResi([String? scannedValue]) async {
    if (processing) return;
    final resi = (scannedValue ?? resiController.text).trim().toUpperCase();
    if (resi.isEmpty) {
      message('Nomor resi wajib diisi.');
      return;
    }
    if (_token == null) {
      message('Sesi login belum tersedia. Buka kembali halaman ini.');
      return;
    }

    setState(() => processing = true);
    try {
      final response = await ApiClient.dio.get<dynamic>(
        '/packing/scan/${Uri.encodeComponent(resi)}',
        options: _authOptions,
      );
      final payload = _map(response.data);
      if (payload['success'] != true) {
        throw Exception(_text(payload['message'], fallback: 'Resi tidak ditemukan.'));
      }
      final order = _map(payload['data']);
      final noPesanan = _text(order['noPesanan'], fallback: '');
      if (noPesanan.isEmpty) {
        throw Exception('Nomor pesanan tidak ditemukan pada respons scan.');
      }
      if (_platform == 'marketplace' &&
          _text(order['platform']).toLowerCase() == 'meta') {
        message('Akun Packing Marketplace tidak dapat memproses pesanan Meta.');
        return;
      }
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Konfirmasi Pengiriman'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                detailLine('Nomor Resi', _text(order['noResi'])),
                detailLine('Pesanan', noPesanan),
                detailLine('Pembeli', _text(order['pembeli'])),
                detailLine('Platform', _text(order['platform'])),
                detailLine('Marketplace', _text(order['marketplace'])),
                detailLine('Kurir', _text(order['kurir'])),
                const SizedBox(height: 12),
                const Text('Pastikan paket sudah selesai dipacking. '
                    'Lanjutkan perubahan status menjadi Dikirim?'),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Batal'),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.pop(dialogContext, true),
              icon: const Icon(Icons.local_shipping_outlined),
              label: const Text('Ya, Kirim'),
            ),
          ],
        ),
      );
      if (!mounted || confirmed != true) return;

      // Validasi status, duplikasi scan, dan kesiapan paket wajib
      // dipastikan pada backend sebelum mengubah status.
      final updateResponse = await ApiClient.dio.patch<dynamic>(
        '/packing/scan/update/${Uri.encodeComponent(noPesanan)}',
        options: _authOptions,
      );
      final result = _map(updateResponse.data);
      if (result['success'] != true) {
        throw Exception(_text(result['message'], fallback: 'Gagal memproses pengiriman.'));
      }
      final updated = _map(result['data']);
      if (_text(updated['status']).toLowerCase() != 'kirim') {
        throw Exception('Server belum mengonfirmasi status dikirim.');
      }
      if (!mounted) return;
      setState(() {
        lastSuccessResi = resi;
        resiController.clear();
      });
      message('Resi $resi berhasil diproses sebagai Dikirim.');
      await _loadReady(silent: true);
    } catch (error) {
      message(_errorMessage(error));
    } finally {
      if (mounted) setState(() => processing = false);
    }
  }

  Future<void> openCameraScanner() async {
    if (processing || _cameraOpen) return;
    _cameraOpen = true;
    try {
      final scannedValue = await Navigator.push<String>(
        context,
        MaterialPageRoute(builder: (_) => const PackingCameraScannerPage()),
      );
      if (!mounted || scannedValue == null) return;
      final resi = scannedValue.trim().toUpperCase();
      resiController.text = resi;
      await processResi(resi);
    } finally {
      _cameraOpen = false;
    }
  }

  static Widget detailLine(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 95,
            child: Text(label,
                style: const TextStyle(fontSize: 12, color: Colors.black54)),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  Widget panel(String title, Widget child) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 15),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE5EBF2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.navy)),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }

  Widget readyOrderCard(Map<String, dynamic> order) {
    final noPesanan = _text(order['noPesanan']);
    final resi = _text(order['noResi'], fallback: '');
    return Container(
      margin: const EdgeInsets.only(bottom: 11),
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: const Color(0xFFE5EBF2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
              child: Text(noPesanan,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      color: AppTheme.navy,
                      fontSize: 14)),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFFEAF7F0),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Text('Siap Dikirim',
                  style: TextStyle(
                      color: Color(0xFF0B8B65),
                      fontSize: 10,
                      fontWeight: FontWeight.bold)),
            ),
          ]),
          const SizedBox(height: 11),
          detailLine('Pembeli', _text(order['pembeli'])),
          detailLine('Platform', _text(order['platform'])),
          detailLine('Marketplace', _text(order['marketplace'])),
          detailLine('No. Resi', resi.isEmpty ? 'Belum ada' : resi),
          if (_text(order['batasKirim'], fallback: '').isNotEmpty)
            detailLine('Batas Kirim', _formatDeadline(order['batasKirim'])),
          if (_platform == 'meta' &&
              _text(order['platform'], fallback: '').toLowerCase() == 'meta' &&
              noPesanan != '-') ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: processing
                    ? null
                    : () => ChatOrderLauncher.open(
                          context,
                          noPesanan: noPesanan,
                        ),
                icon: const Icon(Icons.chat_bubble_outline),
                label: const Text('Chat Klarifikasi'),
              ),
            ),
          ],
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: processing || resi.isEmpty
                  ? null
                  : () {
                      resiController.text = resi;
                      processResi(resi);
                    },
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Cari Pesanan'),
            ),
          ),
        ],
      ),
    );
  }

  static String _formatDeadline(Object? value) {
    final raw = _text(value);
    if (raw == '-') return raw;
    try {
      final date = DateTime.parse(raw).toLocal();
      String two(int value) => value.toString().padLeft(2, '0');
      return '${date.year}-${two(date.month)}-${two(date.day)} '
          '${two(date.hour)}:${two(date.minute)}';
    } catch (_) {
      return raw;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _refreshTimer?.cancel();
    _loadSequence++;
    resiController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(18, 20, 18, 24),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF103961), Color(0xFF145B91)],
              ),
              borderRadius: BorderRadius.vertical(bottom: Radius.circular(24)),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Scan Pengiriman',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 23,
                        fontWeight: FontWeight.bold)),
                SizedBox(height: 6),
                Text('Scan resi setelah packing selesai',
                    style: TextStyle(color: Color(0xFFD2E5F7), fontSize: 12)),
              ],
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => _loadReady(),
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(15),
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: processing ? null : openCameraScanner,
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 20),
                        backgroundColor: AppTheme.primary,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      child: const Column(
                        children: [
                          Icon(Icons.qr_code_scanner, size: 38),
                          SizedBox(height: 8),
                          Text('Scan Barcode Resi',
                              style: TextStyle(fontSize: 17,
                                  fontWeight: FontWeight.bold)),
                          SizedBox(height: 4),
                          Text('Buka kamera untuk scan paket',
                              style: TextStyle(fontSize: 12)),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 15),
                  Container(
                    padding: const EdgeInsets.all(13),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEAF4FD),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Row(children: [
                      Icon(Icons.info_outline, color: AppTheme.primary),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Scan resi Meta, Shopee, atau TikTok sesuai akses akun. '
                          'Pastikan paket sudah selesai dipacking.',
                          style: TextStyle(fontSize: 12, color: AppTheme.navy),
                        ),
                      ),
                    ]),
                  ),
                  const SizedBox(height: 15),
                  panel(
                    'Masukkan Resi Manual',
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextField(
                          controller: resiController,
                          textCapitalization: TextCapitalization.characters,
                          textInputAction: TextInputAction.done,
                          onSubmitted: (_) => processResi(),
                          decoration: const InputDecoration(
                            labelText: 'Nomor Resi',
                            hintText: 'Scan barcode atau ketik resi',
                            prefixIcon: Icon(Icons.qr_code_scanner),
                          ),
                        ),
                        const SizedBox(height: 14),
                        FilledButton.icon(
                          onPressed: processing ? null : () => processResi(),
                          icon: const Icon(Icons.search),
                          label: Text(processing ? 'Mencari...' : 'Cari Pesanan'),
                        ),
                        const SizedBox(height: 10),
                        const Text(
                          'Scanner barcode fisik dapat mengetik nomor resi pada '
                          'kolom di atas. Tekan Enter untuk memproses.',
                          style: TextStyle(
                              fontSize: 11,
                              color: Colors.black54,
                              height: 1.5),
                        ),
                      ],
                    ),
                  ),
                  if (lastSuccessResi != null)
                    Container(
                      margin: const EdgeInsets.only(bottom: 15),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEAF7F0),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(children: [
                        const Icon(Icons.check_circle, color: Color(0xFF0B8B65)),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text('Resi $lastSuccessResi berhasil dikirim.',
                              style: const TextStyle(
                                  color: Color(0xFF0B8B65),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600)),
                        ),
                      ]),
                    ),
                  Row(children: [
                    const Expanded(
                      child: Text('Antrean Siap Dikirim',
                          style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.bold,
                              color: AppTheme.navy)),
                    ),
                    if (!_loadingReady)
                      Text('${_readyOrders.length} pesanan',
                          style: const TextStyle(
                              fontSize: 12, color: Colors.black54)),
                    IconButton(
                      tooltip: 'Muat ulang antrean',
                      onPressed: _loadingReady ? null : () => _loadReady(),
                      icon: const Icon(Icons.refresh),
                    ),
                  ]),
                  const SizedBox(height: 12),
                  if (_loadingReady)
                    const Padding(
                      padding: EdgeInsets.all(25),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (_readyError != null) ...[
                    Text(_readyError!,
                        style: const TextStyle(color: Colors.red)),
                    const SizedBox(height: 10),
                    OutlinedButton(
                      onPressed: () => _loadReady(),
                      child: const Text('Coba Lagi'),
                    ),
                  ] else if (_readyOrders.isEmpty)
                    Container(
                      padding: const EdgeInsets.all(28),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: const Column(children: [
                        Icon(Icons.inventory_2_outlined,
                            size: 43, color: Colors.grey),
                        SizedBox(height: 12),
                        Text('Belum ada paket siap dikirim',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontWeight: FontWeight.bold)),
                      ]),
                    )
                  else
                    for (final order in _readyOrders) readyOrderCard(order),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(13),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF4E6),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Text(
                      'Pencarian resi tidak mengubah status pesanan. '
                      'Status berubah setelah menekan Ya, Kirim.',
                      style: TextStyle(
                          color: Color(0xFF8D570F), fontSize: 11, height: 1.5),
                    ),
                  ),
                  const SizedBox(height: 25),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class PackingCameraScannerPage extends StatefulWidget {
  const PackingCameraScannerPage({super.key});

  @override
  State<PackingCameraScannerPage> createState() =>
      _PackingCameraScannerPageState();
}

class _PackingCameraScannerPageState extends State<PackingCameraScannerPage> {
  final MobileScannerController scannerController = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool detected = false;

  void onDetect(BarcodeCapture capture) {
    if (detected || !mounted) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue?.trim();
      if (value == null || value.isEmpty) continue;
      detected = true;
      Navigator.pop(context, value);
      return;
    }
  }

  @override
  void dispose() {
    scannerController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Scan Barcode Resi'),
        backgroundColor: AppTheme.navy,
        foregroundColor: Colors.white,
      ),
      body: SafeArea(
        child: Stack(children: [
          MobileScanner(controller: scannerController, onDetect: onDetect),
          Align(
            alignment: Alignment.center,
            child: IgnorePointer(
              child: Container(
                width: 280,
                height: 180,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white, width: 3),
                  borderRadius: BorderRadius.circular(15),
                ),
              ),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(24),
              color: Colors.black.withValues(alpha: 0.60),
              child: const Text(
                'Arahkan kamera ke barcode atau QR code pada label resi. '
                'Setelah terdeteksi, aplikasi akan memeriksa pesanan.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white, fontSize: 13, height: 1.5),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}
