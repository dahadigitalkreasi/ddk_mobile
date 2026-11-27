import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:share_plus/share_plus.dart';

import '../../../app/app_theme.dart';
import '../../../core/network/api_client.dart';
import '../../chat/pages/chat_order_launcher.dart';
import 'cs_manage_order_page.dart';
import 'cs_order_complaint_page.dart';

class _DetailOrder {
  final String number;
  final String buyer;
  final String resi;
  final String status;
  final String date;
  final num totalPrice;

  const _DetailOrder({
    required this.number,
    required this.buyer,
    required this.resi,
    required this.status,
    required this.date,
    required this.totalPrice,
  });
}

class CsOrderDetailSheet extends StatefulWidget {
  final _DetailOrder _order;
  final FlutterSecureStorage storage;

  CsOrderDetailSheet({
    super.key,
    required String noPesanan,
    required String namaPembeli,
    required String noResi,
    required String status,
    required String tanggalInput,
    required num totalHarga,
    required this.storage,
  }) : _order = _DetailOrder(
         number: noPesanan,
         buyer: namaPembeli,
         resi: noResi,
         status: status,
         date: tanggalInput,
         totalPrice: totalHarga,
       );

  @override
  State<CsOrderDetailSheet> createState() => _CsOrderDetailSheetState();
}

class _CsOrderDetailSheetState extends State<CsOrderDetailSheet> {
  Map<String, dynamic>? detail;
  bool loading = true;
  String? error;

  @override
  void initState() {
    super.initState();
    _loadDetail();
  }

  Future<void> _loadDetail() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final token = await widget.storage.read(key: 'auth_token');
      if (token == null || token.isEmpty) {
        throw StateError('Sesi login tidak ditemukan. Silakan login kembali.');
      }
      final response = await ApiClient.dio.get<dynamic>(
        '/pesanan/detail/${Uri.encodeComponent(widget._order.number)}',
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      final body = response.data;
      if (body is! Map || body['success'] != true || body['data'] is! Map) {
        throw const FormatException(
          'Format detail pesanan dari API belum sesuai.',
        );
      }
      if (!mounted) {
        return;
      }
      setState(() {
        detail = Map<String, dynamic>.from(body['data'] as Map);
        loading = false;
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        loading = false;
        error = _errorMessage(e);
      });
    }
  }

  Future<void> _openManageOrder() async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => CsManageOrderPage(noPesanan: widget._order.number),
      ),
    );
    if (!mounted) {
      return;
    }
    if (changed == true) {
      Navigator.of(context).pop(true);
    }
  }

  Future<void> _openComplaint() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => CsOrderComplaintPage(noPesanan: widget._order.number),
      ),
    );
  }

  void _copyValue(String value, String label) {
    if (value.trim().isEmpty) return;
    Clipboard.setData(ClipboardData(text: value));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$label berhasil disalin.'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Widget _headerStatus(String status) {
    const palette = <String, (Color, Color, IconData)>{
      'proses': (Color(0xFFFFE9B8), Color(0xFF805400), Icons.schedule_rounded),
      'kirim': (
        Color(0xFFDDEEFF),
        Color(0xFF145C9B),
        Icons.local_shipping_outlined,
      ),
      'selesai': (
        Color(0xFFDFF5E6),
        Color(0xFF17683C),
        Icons.check_circle_outline,
      ),
      'batal': (Color(0xFFFFE0E0), Color(0xFFA12C32), Icons.cancel_outlined),
      'affiliate': (Color(0xFFEFE7FF), Color(0xFF6442A1), Icons.people_outline),
      'pengembalian': (
        Color(0xFFFFECD8),
        Color(0xFF9B511E),
        Icons.keyboard_return_rounded,
      ),
      'pengiriman_gagal': (
        Color(0xFFFFE0E0),
        Color(0xFFA12C32),
        Icons.error_outline,
      ),
    };
    final style =
        palette[status] ??
        (const Color(0xFFE9EDF2), const Color(0xFF344256), Icons.info_outline);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: style.$1,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(style.$3, size: 14, color: style.$2),
          const SizedBox(width: 5),
          Text(
            _statusLabel(status),
            style: TextStyle(
              color: style.$2,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buyerInfo(String title, String value, {bool multiline = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF708095),
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  value.trim().isEmpty ? '-' : value,
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppTheme.navy,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: multiline ? null : 3,
                  overflow: multiline ? null : TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (value.trim().isNotEmpty)
            IconButton(
              tooltip: 'Salin $title',
              visualDensity: VisualDensity.compact,
              onPressed: () => _copyValue(value, title),
              icon: const Icon(
                Icons.copy_rounded,
                size: 18,
                color: Color(0xFF708095),
              ),
            ),
        ],
      ),
    );
  }

  String _tanggalOrderLabel(Object? raw) {
    final text = _asText(raw).trim();
    if (text.isEmpty) return 'Tanggal order belum tersedia';
    final parsed = DateTime.tryParse(text.replaceFirst(' ', 'T'));
    final date = parsed?.isUtc == true ? parsed!.toLocal() : parsed;
    if (date == null) return text;
    const bulan = [
      'Januari',
      'Februari',
      'Maret',
      'April',
      'Mei',
      'Juni',
      'Juli',
      'Agustus',
      'September',
      'Oktober',
      'November',
      'Desember',
    ];
    String two(int n) => n.toString().padLeft(2, '0');
    final jam = '${two(date.hour)}.${two(date.minute)}';
    return '${date.day} ${bulan[date.month - 1]} ${date.year} • $jam';
  }

  Widget _panel({required Widget child}) => Container(
    padding: const EdgeInsets.all(15),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: const Color(0xFFE5EBF2)),
    ),
    child: child,
  );

  Widget _accordion({
    required String title,
    required String subtitle,
    required IconData icon,
    required Widget child,
    bool initiallyExpanded = false,
  }) {
    return Container(
      margin: const EdgeInsets.only(top: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE5EBF2)),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: initiallyExpanded,
          tilePadding: const EdgeInsets.symmetric(horizontal: 15, vertical: 3),
          childrenPadding: const EdgeInsets.fromLTRB(15, 0, 15, 15),
          leading: Icon(icon, color: AppTheme.primary),
          title: Text(
            title,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 14,
              color: AppTheme.navy,
            ),
          ),
          subtitle: Text(subtitle, style: const TextStyle(fontSize: 11)),
          children: [const Divider(height: 14), child],
        ),
      ),
    );
  }

  Widget _photoGallery({
    required String title,
    required List<String> photos,
    required FlutterSecureStorage storage,
    required String itemKey,
    required String emptyLabel,
    bool canShare = false,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$title (${photos.length})',
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: AppTheme.navy,
          ),
        ),
        const SizedBox(height: 8),
        if (photos.isEmpty)
          Container(
            height: 112,
            width: double.infinity,
            alignment: Alignment.center,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFFF4F7FA),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              emptyLabel,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 11, color: Color(0xFF708095)),
            ),
          )
        else
          SizedBox(
            height: 112,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: photos.length,
              separatorBuilder: (_, index) => const SizedBox(width: 7),
              itemBuilder: (context, index) => _OrderPhoto(
                key: ValueKey('$itemKey-$index-${photos[index]}'),
                url: photos[index],
                storage: storage,
                title: '$title • Foto ${index + 1}',
                canShare: canShare,
                shareName:
                    'foto_packing_${widget._order.number}_${index + 1}.${_photoExtension(photos[index])}',
              ),
            ),
          ),
      ],
    );
  }

  Widget _actionButton(String text, IconData icon, VoidCallback? onTap) {
    return Expanded(
      child: OutlinedButton(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 22),
            const SizedBox(height: 5),
            Text(
              text,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final order = widget._order;
    final data = detail;
    final pembeli = _asMap(data?['informasiPembeli']);
    final alamat = _asMap(pembeli['address']);
    final pesanan = _asMap(data?['pesanan']);
    final produkList = _asListOfMaps(data?['informasiProduk']);
    final pembayaranList = _asListOfMaps(data?['pembayaran']);
    final pembayaran = pembayaranList.isEmpty
        ? <String, dynamic>{}
        : pembayaranList.first;
    final alamatLengkap = [
      _asText(alamat['alamatLengkap']),
      ...[
        'desa',
        'kecamatan',
        'kabupatenKota',
        'provinsi',
      ].map((key) => _asText(alamat[key])).where((v) => v.isNotEmpty),
      if (_asText(alamat['kodePos']).isNotEmpty) _asText(alamat['kodePos']),
    ].join(', ');
    final namaPembeli = _asText(pembeli['namaPembeli'], fallback: order.buyer);
    final phone = _asText(pembeli['phone']);
    final noResi = _asText(pesanan['noResi'], fallback: order.resi);
    final totalHarga = _asNumber(
      pesanan['totalHarga'],
      fallback: order.totalPrice,
    );
    final catatan = _asText(pesanan['catatanPesanan']);
    final buktiBayar = _asText(pembayaran['bukti_bayar']).trim();
    // Tanggal order memang sama dengan tanggal input menurut aturan DDK.
    final tanggalInput =
        pesanan['tanggalInput'] ??
        pesanan['input_at'] ??
        pesanan['inputAt'] ??
        order.date;
    final totalHpp = _firstMoney(pesanan, const ['totalHpp', 'total_hpp']);
    final totalAdmin = _firstMoney(pesanan, const [
      'totalAdmin',
      'total_admin',
    ]);
    final ongkir = _firstMoney(pesanan, const [
      'ongkir',
      'biayaOngkir',
      'biaya_ongkir',
      'ongkosKirim',
      'ongkos_kirim',
    ]);
    final iklan = _firstMoney(pesanan, const [
      'biayaIklan',
      'biaya_iklan',
      'totalIklan',
      'total_iklan',
    ]);
    // Jangan menampilkan estimasi keuntungan jika ada biaya yang belum tercatat.
    final keuntungan =
        totalHpp == null ||
            totalAdmin == null ||
            ongkir == null ||
            iklan == null
        ? null
        : totalHarga - totalHpp - totalAdmin - ongkir - iklan;
    final method = _asText(pembayaran['jenis_transaksi']).toLowerCase().trim();

    return SafeArea(
      top: false,
      child: FractionallySizedBox(
        heightFactor: 0.92,
        child: Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 42,
              height: 5,
              decoration: BoxDecoration(
                color: const Color(0xFFD6E0EA),
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 10, 8),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Detail Pesanan',
                      style: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.bold,
                        color: AppTheme.navy,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Tutup',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(15, 8, 15, 20),
                children: [
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(17),
                      border: Border.all(color: const Color(0xFFE5EBF2)),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      children: [
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(17),
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              colors: [Color(0xFF103961), Color(0xFF145B91)],
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  const Expanded(
                                    child: Text(
                                      'DETAIL PESANAN',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: Color(0xFFD2E5F7),
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  _headerStatus(order.status),
                                ],
                              ),
                              const SizedBox(height: 12),
                              const Text(
                                'Nomor Pesanan',
                                style: TextStyle(
                                  color: Color(0xFFD2E5F7),
                                  fontSize: 11,
                                ),
                              ),
                              Row(
                                children: [
                                  Expanded(
                                    child: SelectableText(
                                      order.number,
                                      style: const TextStyle(
                                        fontSize: 20,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: 'Salin nomor pesanan',
                                    onPressed: () => _copyValue(
                                      order.number,
                                      'Nomor pesanan',
                                    ),
                                    icon: const Icon(
                                      Icons.copy_rounded,
                                      color: Colors.white,
                                      size: 19,
                                    ),
                                  ),
                                ],
                              ),
                              const Divider(color: Color(0xFF44779A)),
                              const Text(
                                'Keuntungan Pesanan',
                                style: TextStyle(
                                  color: Color(0xFFD2E5F7),
                                  fontSize: 11,
                                ),
                              ),
                              const SizedBox(height: 5),
                              Text(
                                keuntungan == null ? '—' : _rupiah(keuntungan),
                                style: const TextStyle(
                                  fontSize: 23,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                ),
                              ),
                              if (keuntungan == null) ...[
                                const SizedBox(height: 4),
                                const Text(
                                  'Belum dapat dihitung: data biaya belum lengkap',
                                  style: TextStyle(
                                    color: Color(0xFFD2E5F7),
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(15),
                          child: Column(
                            children: [
                              Row(
                                children: [
                                  const Icon(
                                    Icons.calendar_month_outlined,
                                    size: 22,
                                    color: AppTheme.primary,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        const Text(
                                          'Tanggal Order',
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: Color(0xFF708095),
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          _tanggalOrderLabel(tanggalInput),
                                          style: const TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w600,
                                            color: AppTheme.navy,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              const Divider(height: 24),
                              Row(
                                children: [
                                  const Icon(
                                    Icons.local_shipping_outlined,
                                    size: 22,
                                    color: AppTheme.primary,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        const Text(
                                          'Nomor Resi',
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: Color(0xFF708095),
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          noResi.isEmpty
                                              ? 'Belum ada resi'
                                              : noResi,
                                          style: const TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w600,
                                            color: AppTheme.navy,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  if (noResi.isNotEmpty)
                                    IconButton(
                                      tooltip: 'Salin nomor resi',
                                      onPressed: () =>
                                          _copyValue(noResi, 'Nomor resi'),
                                      icon: const Icon(
                                        Icons.copy_rounded,
                                        size: 18,
                                        color: Color(0xFF708095),
                                      ),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (loading)
                    const Padding(
                      padding: EdgeInsets.all(32),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (error != null)
                    _panel(
                      child: _MessagePanel(
                        icon: Icons.error_outline,
                        title: 'Detail belum dapat dimuat',
                        description: error!,
                        onRetry: _loadDetail,
                      ),
                    )
                  else if (data != null) ...[
                    _panel(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Row(
                            children: [
                              Icon(
                                Icons.person_outline,
                                color: AppTheme.primary,
                                size: 21,
                              ),
                              SizedBox(width: 9),
                              Text(
                                'Informasi Pembeli',
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.bold,
                                  color: AppTheme.navy,
                                ),
                              ),
                            ],
                          ),
                          const Divider(height: 22),
                          _buyerInfo('Nama Pembeli', namaPembeli),
                          _buyerInfo('Nomor WhatsApp', phone),
                          _buyerInfo(
                            'Alamat Pengiriman',
                            alamatLengkap,
                            multiline: true,
                          ),
                        ],
                      ),
                    ),
                    _accordion(
                      title: 'Informasi Produk',
                      subtitle:
                          '${produkList.length} jenis produk • ketuk untuk melihat',
                      icon: Icons.inventory_2_outlined,
                      initiallyExpanded: true,
                      child: produkList.isEmpty
                          ? const Text('Belum ada informasi produk.')
                          : Column(
                              children: produkList.asMap().entries.map((entry) {
                                final i = entry.key;
                                final item = entry.value;
                                final master = _asMap(item['produk']);
                                final namaProduk = _asText(
                                  master['nama_produk'],
                                  fallback: _asText(master['namaProduk']),
                                );
                                final variasi = _asText(master['variasi']);
                                final fotoUrls = _asListOfMaps(item['reqfoto'])
                                    .map((f) => _asText(f['foto']).trim())
                                    .where((url) => url.isNotEmpty)
                                    .toList();
                                final fotoMeta = _packingPhotoSources(
                                  item['foto_meta'],
                                );
                                final fotoPackingUrls = fotoMeta.where((
                                  source,
                                ) {
                                  final uri = Uri.tryParse(source);
                                  return uri != null &&
                                      (uri.scheme == 'https' ||
                                          uri.scheme == 'http') &&
                                      uri.hasAuthority;
                                }).toList();
                                final fotoPackingButuhUrl =
                                    fotoMeta.isNotEmpty &&
                                    fotoPackingUrls.isEmpty;
                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 14),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Container(
                                            height: 44,
                                            width: 44,
                                            decoration: BoxDecoration(
                                              color: const Color(0xFFEAF4FD),
                                              borderRadius:
                                                  BorderRadius.circular(10),
                                            ),
                                            child: const Icon(
                                              Icons.inventory_2_outlined,
                                              color: AppTheme.primary,
                                            ),
                                          ),
                                          const SizedBox(width: 10),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  namaProduk.isEmpty
                                                      ? 'Produk ${i + 1}'
                                                      : namaProduk,
                                                  style: const TextStyle(
                                                    fontSize: 13,
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                ),
                                                if (variasi.isNotEmpty)
                                                  Text(
                                                    variasi,
                                                    style: const TextStyle(
                                                      fontSize: 11,
                                                      color: Colors.black54,
                                                    ),
                                                  ),
                                                Text(
                                                  '${_asText(item['jumlah'], fallback: '0')} pcs • SKU ${_asText(item['sku'])}',
                                                  style: const TextStyle(
                                                    fontSize: 11,
                                                    color: Colors.black54,
                                                  ),
                                                ),
                                                if (_asText(item['harga'])
                                                    .isNotEmpty)
                                                  Padding(
                                                    padding:
                                                        const EdgeInsets.only(
                                                          top: 5,
                                                        ),
                                                    child: Text(
                                                      _rupiah(
                                                        _asNumber(
                                                          item['harga'],
                                                        ),
                                                      ),
                                                      style: const TextStyle(
                                                        fontSize: 13,
                                                        fontWeight:
                                                            FontWeight.bold,
                                                        color: AppTheme.navy,
                                                      ),
                                                    ),
                                                  ),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                      if (_asText(item['catatan']).isNotEmpty)
                                        _DetailRow(
                                          'Catatan',
                                          _asText(item['catatan']),
                                        ),
                                      const SizedBox(height: 12),
                                      Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Expanded(
                                            child: _photoGallery(
                                              title: 'Foto Request',
                                              photos: fotoUrls,
                                              storage: widget.storage,
                                              itemKey:
                                                  'req-${item['id_per_produk']}',
                                              emptyLabel:
                                                  'Belum ada foto request',
                                            ),
                                          ),
                                          const SizedBox(width: 10),
                                          Expanded(
                                            child: _photoGallery(
                                              title: 'Foto Packing',
                                              photos: fotoPackingUrls,
                                              storage: widget.storage,
                                              itemKey:
                                                  'packing-${item['id_per_produk']}',
                                              emptyLabel: fotoPackingButuhUrl
                                                  ? 'Tautan foto belum tersedia'
                                                  : 'Belum ada foto packing',
                                              canShare: true,
                                            ),
                                          ),
                                        ],
                                      ),
                                      if (i < produkList.length - 1)
                                        const Padding(
                                          padding: EdgeInsets.only(top: 12),
                                          child: Divider(height: 1),
                                        ),
                                    ],
                                  ),
                                );
                              }).toList(),
                            ),
                    ),
                    _accordion(
                      title: 'Pembayaran',
                      subtitle: 'Metode bayar, pendapatan, dan rincian biaya',
                      icon: Icons.account_balance_wallet_outlined,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _DetailRow('Metode', _paymentName(method)),
                          if (method == 'cod')
                            _DetailRow('COD', _moneyText(pembayaran['cod']))
                          else if (method == 'non-cod' || method == 'non_cod')
                            _DetailRow(
                              'Non-COD',
                              _moneyText(pembayaran['non_cod']),
                            )
                          else if (method == 'dp') ...[
                            _DetailRow(
                              'DP (uang muka)',
                              _moneyText(pembayaran['dp']),
                            ),
                            _DetailRow(
                              'Sisa COD',
                              _moneyText(pembayaran['cod']),
                            ),
                          ] else if (method == 'por')
                            _DetailRow(
                              'POR (bayar setelah jadi)',
                              _moneyText(pembayaran['por']),
                            )
                          else
                            const Padding(
                              padding: EdgeInsets.only(top: 8),
                              child: Text(
                                'Metode pembayaran belum tersedia.',
                                style: TextStyle(
                                  color: Colors.black54,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          if (method == 'por')
                            const Padding(
                              padding: EdgeInsets.only(top: 6, bottom: 6),
                              child: Text(
                                'Nominal POR bukan bukti pelunasan. '
                                'Status pembayaran perlu dikonfirmasi terpisah.',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Color(0xFF708095),
                                ),
                              ),
                            ),
                          const Divider(height: 24),
                          const Text(
                            'Rincian Pesanan',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: AppTheme.navy,
                            ),
                          ),
                          const SizedBox(height: 5),
                          _DetailRow('Total Pesanan', _rupiah(totalHarga)),
                          _DetailRow('HPP', _moneyOrDash(totalHpp)),
                          _DetailRow('Ongkir', _moneyOrDash(ongkir)),
                          _DetailRow('Biaya Admin', _moneyOrDash(totalAdmin)),
                          _DetailRow('Biaya Iklan', _moneyOrDash(iklan)),
                          const Divider(height: 18),
                          _DetailRow(
                            'Keuntungan',
                            keuntungan == null ? '—' : _rupiah(keuntungan),
                          ),
                          if (keuntungan == null)
                            const Padding(
                              padding: EdgeInsets.only(top: 4),
                              child: Text(
                                'Keuntungan belum dapat dihitung karena '
                                'sebagian biaya belum tersedia.',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Color(0xFF708095),
                                ),
                              ),
                            ),
                          if (buktiBayar.isNotEmpty) ...[
                            const SizedBox(height: 11),
                            const Text(
                              'Bukti Pembayaran',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 9),
                            _OrderPhoto(
                              url: buktiBayar,
                              storage: widget.storage,
                              title: 'Bukti Pembayaran',
                            ),
                          ],
                        ],
                      ),
                    ),
                    _accordion(
                      title: 'Catatan & Chat Masuk',
                      subtitle: 'Waktu chat dan catatan',
                      icon: Icons.event_note_outlined,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (_asText(pesanan['chatMasuk']).isNotEmpty)
                            _DetailRow(
                              'Chat Masuk',
                              _asText(pesanan['chatMasuk']),
                            ),
                          _DetailRow(
                            'Catatan',
                            catatan.isEmpty ? '-' : catatan,
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Container(
              decoration: const BoxDecoration(
                color: Colors.white,
                border: Border(top: BorderSide(color: Color(0xFFE5EBF2))),
              ),
              padding: const EdgeInsets.fromLTRB(15, 10, 15, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      _actionButton(
                        'Chat',
                        Icons.chat_bubble_outline,
                        () => ChatOrderLauncher.open(
                          context,
                          noPesanan: order.number,
                        ),
                      ),
                      const SizedBox(width: 8),
                      _actionButton(
                        'Edit / Hapus',
                        Icons.edit_note_outlined,
                        data != null && !loading && error == null
                            ? _openManageOrder
                            : null,
                      ),
                      const SizedBox(width: 8),
                      _actionButton(
                        'Komplain',
                        Icons.report_problem_outlined,
                        data != null && !loading && error == null
                            ? _openComplaint
                            : null,
                      ),
                    ],
                  ),
                  const SizedBox(height: 5),
                ],
              ),
            ),
          ],
        ),
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
  final bool canShare;
  final String? shareName;

  const _OrderPhoto({
    super.key,
    required this.url,
    required this.title,
    required this.storage,
    this.canShare = false,
    this.shareName,
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
    if (uri == null ||
        !uri.hasAuthority ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw const FormatException('URL gambar tidak valid.');
    }

    final configuredApi = Uri.parse(ApiClient.dio.options.baseUrl);
    final sameOrigin =
        uri.scheme == configuredApi.scheme &&
        uri.host == configuredApi.host &&
        uri.port == configuredApi.port;
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

  Future<void> _sharePhoto(Uint8List bytes) async {
    try {
      // File dibagikan sebagai berkas gambar, bukan URL internal FileGator.
      final name = widget.shareName ?? 'foto_packing.jpg';
      final extension = name.toLowerCase().split('.').last;
      final mime = extension == 'png'
          ? 'image/png'
          : extension == 'webp'
          ? 'image/webp'
          : 'image/jpeg';
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile.fromData(bytes, name: name, mimeType: mime)],
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Foto belum dapat dibagikan. Silakan coba lagi.'),
        ),
      );
    }
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
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                  if (widget.canShare)
                    IconButton(
                      tooltip: 'Bagikan foto packing',
                      icon: const Icon(Icons.share_outlined),
                      onPressed: () => _sharePhoto(bytes),
                    ),
                  IconButton(
                    tooltip: 'Tutup',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(dialogContext),
                  ),
                ],
              ),
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
    final path =
        Uri.tryParse(widget.url)?.queryParameters['path'] ?? widget.url;
    if (path.toLowerCase().endsWith('.pdf')) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFFF4F7FA),
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.picture_as_pdf_outlined),
            SizedBox(width: 8),
            Text('Bukti bayar PDF tersedia (tanpa pratinjau gambar)'),
          ],
        ),
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
                  Text(
                    'Gagal memuat\nKetuk ulang',
                    style: TextStyle(fontSize: 11),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          );
        }
        final bytes = snapshot.data!;
        return InkWell(
          onTap: () => _openPreview(bytes),
          borderRadius: BorderRadius.circular(10),
          child: Stack(
            children: [
              ClipRRect(
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
              if (widget.canShare)
                Positioned(
                  right: 4,
                  bottom: 4,
                  child: Material(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(18),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(18),
                      onTap: () => _sharePhoto(bytes),
                      child: const Padding(
                        padding: EdgeInsets.all(6),
                        child: Icon(
                          Icons.share_outlined,
                          size: 17,
                          color: AppTheme.navy,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
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

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;
  const _DetailRow(this.label, this.value);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 7),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 110,
          child: Text(
            label,
            style: const TextStyle(fontSize: 12, color: Colors.black54),
          ),
        ),
        Expanded(
          child: Text(
            value.isEmpty ? '-' : value,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ),
  );
}

String _photoExtension(String source) {
  final uri = Uri.tryParse(source);
  final path = uri?.queryParameters['path'] ?? uri?.path ?? source;
  final extension = path.split('.').last.toLowerCase();
  return ['jpg', 'jpeg', 'png', 'webp'].contains(extension) ? extension : 'jpg';
}

num? _firstMoney(Map<String, dynamic> raw, List<String> keys) {
  for (final key in keys) {
    final value = raw[key];
    if (value == null || value.toString().trim().isEmpty) continue;
    if (value is num) return value;
    final parsed = num.tryParse(value.toString());
    if (parsed != null) return parsed;
  }
  return null;
}

String _moneyOrDash(num? value) => value == null ? '—' : _rupiah(value);
String _moneyText(Object? value) => _moneyOrDash(
  value == null || value.toString().trim().isEmpty
      ? null
      : num.tryParse(value.toString()),
);

String _paymentName(String method) {
  switch (method) {
    case 'cod':
      return 'COD (Bayar di Tempat)';
    case 'non-cod':
    case 'non_cod':
      return 'Non-COD (Bayar di Awal)';
    case 'dp':
      return 'DP (Uang Muka)';
    case 'por':
      return 'POR (Bayar Setelah Jadi)';
    default:
      return '—';
  }
}

/// Mengambil lokasi foto packing dari foto_meta tanpa mengasumsikan
/// bahwa semua respons Laravel memakai bentuk data yang sama.
/// Foto hanya dapat ditampilkan jika backend memberikan URL HTTP(S).
List<String> _packingPhotoSources(dynamic value) {
  final results = <String>[];

  void visit(dynamic entry) {
    if (entry == null) return;
    if (entry is String) {
      final text = entry.trim();
      if (text.isNotEmpty) results.add(text);
      return;
    }
    if (entry is List) {
      for (final child in entry) {
        visit(child);
      }
      return;
    }
    if (entry is Map) {
      for (final key in [
        'url',
        'signed_url',
        'signedUrl',
        'foto',
        'path',
        'foto_meta',
      ]) {
        final candidate = entry[key];
        if (candidate != null) {
          visit(candidate);
          return;
        }
      }
    }
  }

  visit(value);
  return results.toSet().toList();
}

Map<String, dynamic> _asMap(dynamic value) =>
    value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

List<Map<String, dynamic>> _asListOfMaps(dynamic value) => value is List
    ? value
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList()
    : [];

num _asNumber(dynamic value, {num fallback = 0}) =>
    value is num ? value : num.tryParse('${value ?? ''}') ?? fallback;

String _asText(dynamic value, {String fallback = ''}) =>
    value == null ? fallback : value.toString();

String _rupiah(num amount) =>
    'Rp${amount.toStringAsFixed(0).replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+(?!\d))'), (m) => '${m[1]}.')}';

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
      return 'Parameter pencarian atau filter tidak valid.';
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
  return 'Terjadi kesalahan saat mengambil pesanan: $error';
}
