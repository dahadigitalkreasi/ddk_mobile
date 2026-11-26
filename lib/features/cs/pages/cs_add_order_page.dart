import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../../../app/app_theme.dart';
import '../../../core/network/api_client.dart';
import '../../orders/services/cs_order_updates.dart';

class CsAddOrderPage extends StatefulWidget {
  final VoidCallback onCancel;
  final bool isLeader;

  const CsAddOrderPage({
    super.key,
    required this.onCancel,
    this.isLeader = false,
  });

  @override
  State<CsAddOrderPage> createState() => _CsAddOrderPageState();
}

class _ProductInput {
  int? categoryId;
  String? product;
  String? sku;
  String? variant;
  num? hpp;
  bool loadingProducts = false;
  String? productsError;

  final qty = TextEditingController(text: '1');
  final note = TextEditingController();
  final List<XFile> photos = [];

  void dispose() {
    qty.dispose();
    note.dispose();
  }
}

class _CategoryOption {
  final int id;
  final String name;
  const _CategoryOption(this.id, this.name);
}

class _VariantOption {
  final String sku;
  final String name;
  final num hpp;
  const _VariantOption(this.sku, this.name, this.hpp);
}

class _ProductOption {
  final String name;
  final List<_VariantOption> variants;
  const _ProductOption(this.name, this.variants);
}

class _RegionOption {
  final String id;
  final String name;
  const _RegionOption(this.id, this.name);
}

class _CsAddOrderPageState extends State<CsAddOrderPage> {
  static const _storage = FlutterSecureStorage();
  String? _orderNumber;
  String? _responsibleName;
  int? _responsibleUserId;
  bool _loadingIdentity = true;
  String? _identityError;

  String get responsibleName => _responsibleName ?? 'Belum dimuat';
  List<_CategoryOption> _categories = [];
  final Map<int, List<_ProductOption>> _productsByCategory = {};
  bool _loadingCategories = true;
  String? _categoriesError;

  Future<String> _bearerToken() async {
    final token = await _storage.read(key: 'auth_token');
    if (token == null || token.trim().isEmpty) {
      throw StateError('Token login tidak ditemukan. Silakan login ulang.');
    }
    return token;
  }

  String _apiError(Object error, String fallback) {
    if (error is DioException) {
      if (error.response?.statusCode == 401) return 'Sesi login sudah tidak valid.';
      if (error.response?.statusCode == 404) return 'Endpoint API tidak ditemukan.';
      return 'Tidak dapat mengambil data dari Laravel (${error.response?.statusCode ?? 'koneksi'}).';
    }
    if (error is FormatException || error is StateError) return error.toString();
    return fallback;
  }

  Future<void> _loadCategories() async {
    setState(() { _loadingCategories = true; _categoriesError = null; });
    try {
      final token = await _bearerToken();
      final response = await ApiClient.dio.get<dynamic>(
        '/kategoris',
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      final body = response.data;
      if (body is! Map || body['success'] != true || body['data'] is! List) {
        throw const FormatException('Format daftar kategori tidak sesuai API.');
      }
      final parsed = <_CategoryOption>[];
      for (final entry in body['data'] as List) {
        if (entry is! Map) continue;
        final id = int.tryParse(entry['id']?.toString() ?? '');
        final name = (entry['nama_kategori'] ?? entry['nama'] ?? '').toString().trim();
        if (id != null && name.isNotEmpty) parsed.add(_CategoryOption(id, name));
      }
      if (!mounted) return;
      setState(() { _categories = parsed; _loadingCategories = false; });
    } catch (error) {
      if (!mounted) return;
      setState(() { _categoriesError = _apiError(error, 'Gagal memuat kategori.'); _loadingCategories = false; });
    }
  }

  Future<void> _selectCategory(_ProductInput item, int? categoryId, {bool forceReload = false}) async {
    setState(() {
      item.categoryId = categoryId;
      item.product = null;
      item.sku = null;
      item.variant = null;
      item.hpp = null;
      item.productsError = null;
      item.loadingProducts = categoryId != null &&
          (forceReload || !_productsByCategory.containsKey(categoryId));
    });
    if (categoryId == null ||
        (!forceReload && _productsByCategory.containsKey(categoryId))) {
      return;
    }
    try {
      final token = await _bearerToken();
      final response = await ApiClient.dio.get<dynamic>(
        '/produk/$categoryId',
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      final body = response.data;
      if (body is! Map || body['success'] != true || body['data'] is! List) {
        throw const FormatException('Format daftar produk tidak sesuai API.');
      }
      final parsed = <_ProductOption>[];
      for (final raw in body['data'] as List) {
        if (raw is! Map) continue;
        final name = raw['nama_produk']?.toString().trim() ?? '';
        final variants = <_VariantOption>[];
        final list = raw['variasi'];
        if (list is List) {
          for (final v in list) {
            if (v is! Map) continue;
            final sku = v['sku']?.toString().trim() ?? '';
            final variation = (v['variasi'] ?? v['nama'] ?? '').toString().trim();
            final value = v['hpp'];
            final hpp = value is num ? value : num.tryParse(value?.toString() ?? '') ?? 0;
            if (sku.isNotEmpty) variants.add(_VariantOption(sku, variation.isEmpty ? sku : variation, hpp));
          }
        }
        if (name.isNotEmpty) parsed.add(_ProductOption(name, variants));
      }
      if (!mounted) return;
      setState(() {
        _productsByCategory[categoryId] = parsed;
        if (products.contains(item) && item.categoryId == categoryId) {
          item.loadingProducts = false;
        }
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        if (products.contains(item) && item.categoryId == categoryId) {
          item.loadingProducts = false;
          item.productsError = _apiError(error, 'Gagal memuat produk.');
        }
      });
    }
  }
  // Wilayah menggunakan ID lengkap dari API, bukan teks nama daerah.
  List<_RegionOption> _provinces = [];
  List<_RegionOption> _cities = [];
  List<_RegionOption> _districts = [];
  List<_RegionOption> _villages = [];
  String? _provinceId;
  String? _cityId;
  String? _districtId;
  String? _villageId;
  String? _postalCode;
  bool _loadingProvinces = false;
  bool _loadingCities = false;
  bool _loadingDistricts = false;
  bool _loadingVillages = false;
  String? _provinceError;
  String? _cityError;
  String? _districtError;
  String? _villageError;
  // Cegah respons request lama menimpa pilihan wilayah terbaru.
  int _cityRequest = 0;
  int _districtRequest = 0;
  int _villageRequest = 0;
  int _addressRequest = 0;

  Future<List<_RegionOption>> _fetchRegions(String endpoint) async {
    final token = await _bearerToken();
    final response = await ApiClient.dio.get<dynamic>(
      endpoint,
      options: Options(headers: {'Authorization': 'Bearer $token'}),
    );
    final body = response.data;
    if (body is! Map || body['success'] != true || body['data'] is! List) {
      throw const FormatException('Format respons wilayah tidak sesuai API.');
    }
    final regions = <_RegionOption>[];
    for (final entry in body['data'] as List) {
      if (entry is! Map) continue;
      final id = entry['id']?.toString().trim() ?? '';
      final name = entry['name']?.toString().trim() ?? '';
      if (id.isNotEmpty && name.isNotEmpty) {
        regions.add(_RegionOption(id, name));
      }
    }
    return regions;
  }

  String _regionError(Object error) {
    if (error is DioException) {
      if (error.response?.statusCode == 404) {
        return 'Data wilayah tidak ditemukan (404). Periksa layanan wilayah Laravel.';
      }
      if (error.response?.statusCode == 401) {
        return 'Sesi login tidak valid. Silakan login ulang.';
      }
      if (error.response?.statusCode == 503) {
        return 'Layanan wilayah sedang tidak tersedia (503).';
      }
      return 'Gagal memuat wilayah (${error.response?.statusCode ?? 'koneksi'}).';
    }
    return 'Gagal memuat wilayah. Coba lagi.';
  }

  Future<void> _loadProvinces() async {
    if (!mounted) return;
    setState(() { _loadingProvinces = true; _provinceError = null; });
    try {
      final data = await _fetchRegions('/wilayah/provinsi');
      if (!mounted) return;
      setState(() { _provinces = data; _loadingProvinces = false; });
    } catch (error) {
      if (!mounted) return;
      setState(() { _provinceError = _regionError(error); _loadingProvinces = false; });
    }
  }

  void _selectProvince(String? id) {
    ++_cityRequest;
    ++_districtRequest;
    ++_villageRequest;
    ++_addressRequest;
    setState(() {
      _provinceId = id; _cityId = null; _districtId = null; _villageId = null;
      _cities = []; _districts = []; _villages = []; _postalCode = null;
      province.text = id ?? ''; city.clear(); district.clear(); village.clear();
      _cityError = null; _districtError = null; _villageError = null;
      _loadingCities = false; _loadingDistricts = false; _loadingVillages = false;
    });
    if (id != null) _loadCities(id);
  }

  Future<void> _loadCities(String provinceId) async {
    final request = ++_cityRequest;
    setState(() { _loadingCities = true; _cityError = null; });
    try {
      final data = await _fetchRegions('/wilayah/kabupaten/$provinceId');
      if (!mounted || request != _cityRequest || _provinceId != provinceId) return;
      setState(() { _cities = data; _loadingCities = false; });
    } catch (error) {
      if (!mounted || request != _cityRequest || _provinceId != provinceId) return;
      setState(() { _cityError = _regionError(error); _loadingCities = false; });
    }
  }

  void _selectCity(String? id) {
    ++_districtRequest;
    ++_villageRequest;
    ++_addressRequest;
    setState(() {
      _cityId = id; _districtId = null; _villageId = null;
      _districts = []; _villages = []; _postalCode = null;
      city.text = id ?? ''; district.clear(); village.clear();
      _districtError = null; _villageError = null;
      _loadingDistricts = false; _loadingVillages = false;
    });
    if (id != null) _loadDistricts(id);
  }

  Future<void> _loadDistricts(String cityId) async {
    final request = ++_districtRequest;
    setState(() { _loadingDistricts = true; _districtError = null; });
    try {
      final data = await _fetchRegions('/wilayah/kecamatan/$cityId');
      if (!mounted || request != _districtRequest || _cityId != cityId) return;
      setState(() { _districts = data; _loadingDistricts = false; });
    } catch (error) {
      if (!mounted || request != _districtRequest || _cityId != cityId) return;
      setState(() { _districtError = _regionError(error); _loadingDistricts = false; });
    }
  }

  void _selectDistrict(String? id) {
    ++_villageRequest;
    ++_addressRequest;
    setState(() {
      _districtId = id; _villageId = null;
      _villages = []; _postalCode = null;
      district.text = id ?? ''; village.clear();
      _villageError = null; _loadingVillages = false;
    });
    if (id != null) _loadVillages(id);
  }

  Future<void> _loadVillages(String districtId) async {
    final request = ++_villageRequest;
    setState(() { _loadingVillages = true; _villageError = null; });
    try {
      final data = await _fetchRegions('/wilayah/desa/$districtId');
      if (!mounted || request != _villageRequest || _districtId != districtId) return;
      setState(() { _villages = data; _loadingVillages = false; });
    } catch (error) {
      if (!mounted || request != _villageRequest || _districtId != districtId) return;
      setState(() { _villageError = _regionError(error); _loadingVillages = false; });
    }
  }

  void _selectVillage(String? id) {
    ++_addressRequest;
    setState(() { _villageId = id; village.text = id ?? ''; _postalCode = null; });
    if (id != null) _loadAddressInfo(id);
  }

  // Lookup kode pos hanya pelengkap, tidak menghalangi pengisian alamat.
  Future<void> _loadAddressInfo(String villageId) async {
    final request = ++_addressRequest;
    try {
      final token = await _bearerToken();
      final response = await ApiClient.dio.get<dynamic>(
        '/wilayah/alamat/$villageId',
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      final body = response.data;
      if (body is! Map || body['success'] != true || body['data'] is! Map) return;
      final code = (body['data'] as Map)['kode_pos']?.toString();
      if (!mounted || request != _addressRequest || _villageId != villageId) return;
      setState(() { _postalCode = code; });
    } catch (_) {
      // Alamat detail opsional; pemilihan desa tetap dapat digunakan.
    }
  }

  String _regionName(List<_RegionOption> regions, String? id) {
    for (final option in regions) {
      if (option.id == id) return option.name;
    }
    return '-';
  }

  // Bottom sheet searchable; mencari dari data API yang sudah dimuat.
  Future<T?> _searchOption<T>({
    required String title,
    required List<T> options,
    required String Function(T) labelOf,
    String Function(T)? subtitleOf,
  }) async {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) {
        String query = '';
        return StatefulBuilder(
          builder: (context, updateSheet) {
            final filtered = options.where((option) {
              final text = '${labelOf(option)} ${subtitleOf?.call(option) ?? ''}'.toLowerCase();
              return text.contains(query.toLowerCase().trim());
            }).toList();
            return SafeArea(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  16, 8, 16, MediaQuery.viewInsetsOf(context).bottom + 12,
                ),
                child: SizedBox(
                  height: (MediaQuery.sizeOf(context).height - MediaQuery.viewInsetsOf(context).bottom) * 0.65,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 12),
                      TextField(
                        autofocus: true,
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.search),
                          hintText: 'Ketik untuk mencari...',
                          border: OutlineInputBorder(),
                        ),
                        onChanged: (value) => updateSheet(() => query = value),
                      ),
                      const SizedBox(height: 8),
                      Expanded(
                        child: filtered.isEmpty
                            ? const Center(child: Text('Data tidak ditemukan'))
                            : ListView.builder(
                                itemCount: filtered.length,
                                itemBuilder: (context, index) {
                                  final option = filtered[index];
                                  final subtitle = subtitleOf?.call(option);
                                  return ListTile(
                                    title: Text(labelOf(option)),
                                    subtitle: subtitle == null || subtitle.isEmpty ? null : Text(subtitle),
                                    onTap: () => Navigator.pop(sheetContext, option),
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _searchSelector({
    required String label,
    required String? selectedLabel,
    required VoidCallback? onTap,
    String? error,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          suffixIcon: Icon(onTap == null ? Icons.lock_outline : Icons.search),
          errorText: error,
        ),
        child: Text(
          selectedLabel?.isNotEmpty == true ? selectedLabel! : 'Pilih $label',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: onTap == null ? Colors.black45 : AppTheme.navy),
        ),
      ),
    );
  }

  Widget _regionDropdown({
    required String label,
    required String? selected,
    required List<_RegionOption> options,
    required bool loading,
    required ValueChanged<String?> onChanged,
    String? error,
    VoidCallback? retry,
    bool enabled = true,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 13),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _searchSelector(
            label: label,
            selectedLabel: _regionName(options, selected) == '-' ? null : _regionName(options, selected),
            onTap: enabled && !loading && options.isNotEmpty
                ? () async {
                    final chosen = await _searchOption<_RegionOption>(
                      title: 'Cari $label',
                      options: options,
                      labelOf: (region) => region.name,
                    );
                    if (chosen != null && mounted) onChanged(chosen.id);
                  }
                : null,
          ),
          if (loading) const LinearProgressIndicator(),
          if (error != null) ...[
            const SizedBox(height: 5),
            Text(error, style: const TextStyle(color: Colors.red, fontSize: 12)),
            if (retry != null) Align(
              alignment: Alignment.centerLeft,
              child: TextButton(onPressed: retry, child: const Text('Coba Lagi')),
            ),
          ],
        ],
      ),
    );
  }

  GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final _picker = ImagePicker();

  final buyer = TextEditingController();
  final phone = TextEditingController(text: '62');
  final province = TextEditingController();
  final city = TextEditingController();
  final district = TextEditingController();
  final village = TextEditingController();
  final address = TextEditingController();

  final cod = TextEditingController(text: '0');
  final nonCod = TextEditingController(text: '0');
  final dp = TextEditingController(text: '0');

  final List<_ProductInput> products = [_ProductInput()];

  bool _submitting = false;
  // Jika respons POST tidak diterima, jangan otomatis kirim ulang pesanan.
  bool _submissionUncertain = false;
  String? _uncertainOrderNumber;
  bool _checkingSubmission = false;
  String payment = 'COD';
  XFile? paymentProof;

  DateTime chatDate = DateTime.now();
  DateTime orderDate = DateTime.now();

  @override
  void initState() {
    super.initState();
    _loadOrderIdentity();
    _loadCategories();
    _loadProvinces();
  }

  Future<void> _loadOrderIdentity() async {
    if (mounted) {
      setState(() {
        _loadingIdentity = true;
        _identityError = null;
        _orderNumber = null;
        _responsibleName = null;
        _responsibleUserId = null;
      });
    }

    try {
      final token = await _storage.read(key: 'auth_token');
      if (token == null || token.trim().isEmpty) {
        throw StateError('Token login tidak ditemukan. Silakan login ulang.');
      }

      final response = await ApiClient.dio.get<dynamic>(
        '/pesanan/create',
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      final body = response.data;
      if (body is! Map || body['success'] != true || body['data'] is! Map) {
        throw const FormatException('Format respons API nomor pesanan tidak valid.');
      }
      final data = Map<String, dynamic>.from(body['data'] as Map);
      final user = data['user'];
      final number = data['no_pesanan']?.toString().trim() ?? '';
      if (number.isEmpty || user is! Map) {
        throw const FormatException('Nomor pesanan atau data pengguna tidak tersedia.');
      }
      final userData = Map<String, dynamic>.from(user);
      final id = int.tryParse(userData['id']?.toString() ?? '');
      final name = userData['name']?.toString().trim() ?? '';
      if (id == null || id < 1 || name.isEmpty) {
        throw const FormatException('Identitas pengguna pada respons API tidak valid.');
      }

      if (!mounted) return;
      setState(() {
        _orderNumber = number;
        _responsibleName = name;
        _responsibleUserId = id;
        _loadingIdentity = false;
      });
    } catch (error) {
      if (!mounted) return;
      String message = 'Gagal mengambil nomor pesanan dari Laravel.';
      if (error is DioException) {
        switch (error.response?.statusCode) {
          case 401:
            message = 'Sesi login tidak valid. Silakan login ulang.';
            break;
          case 404:
            message = 'Endpoint GET /api/pesanan/create tidak ditemukan.';
            break;
          default:
            message = 'Tidak dapat menghubungi API Laravel. Periksa koneksi.';
        }
      } else if (error is StateError || error is FormatException) {
        message = error.toString().replaceFirst(RegExp(r'^(Bad state|FormatException): '), '');
      }
      setState(() {
        _identityError = message;
        _loadingIdentity = false;
      });
    }
  }

  @override
  void dispose() {
    for (final controller in [
      buyer,
      phone,
      province,
      city,
      district,
      village,
      address,
      cod,
      nonCod,
      dp,
    ]) {
      controller.dispose();
    }

    for (final product in products) {
      product.dispose();
    }

    super.dispose();
  }

  int amount(TextEditingController controller) {
    return int.tryParse(controller.text.trim()) ?? 0;
  }

  // Hanya komponen pembayaran yang sesuai metode yang dihitung.
  int get nilaiCod => payment == 'COD' || payment == 'DP' ? amount(cod) : 0;
  int get nilaiNonCod => payment == 'NON COD' ? amount(nonCod) : 0;
  int get nilaiDp => payment == 'DP' ? amount(dp) : 0;

  // Total nominal yang benar-benar akan dikirim sebagai total_harga.
  int get totalPrice => nilaiCod + nilaiNonCod + nilaiDp;

  void _changePayment(String nextPayment) {
    setState(() {
      payment = nextPayment;
      // Hilangkan nominal lama ketika mengganti metode pembayaran.
      cod.text = '0';
      nonCod.text = '0';
      dp.text = '0';
      paymentProof = null;
    });
  }

  // Perhitungan HPP dari master produk Laravel.
  int get totalHpp => products.fold<int>(
        0,
        (sum, item) => sum + ((item.hpp ?? 0) * amount(item.qty)).round(),
      );

  int get totalJumlahProduk => products.fold<int>(
        0, (sum, item) => sum + amount(item.qty),
      );

  // Harga jual satuan dihitung dari total transaksi / seluruh pcs.
  double get hargaJualOtomatis => totalJumlahProduk > 0
      ? nilaiTransaksi / totalJumlahProduk
      : 0;

  String hargaJualApi() => hargaJualOtomatis.toStringAsFixed(2);

  // Pembulatan ke rupiah terdekat (3,33% dari COD).
  int get totalAdmin => (nilaiCod * 0.0333).round();

  int get nilaiTransaksi => totalPrice;

  String rupiah(int value) {
    final formatted = value.toString().replaceAllMapped(
      RegExp(r'(\d)(?=(\d{3})+(?!\d))'),
      (match) => '${match[1]}.',
    );
    return 'Rp$formatted';
  }

  String dateLabel(DateTime value) {
    final day = value.day.toString().padLeft(2, '0');
    final month = value.month.toString().padLeft(2, '0');
    return '$day/$month/${value.year}';
  }

  Future<void> selectDate({required bool isChat}) async {
    final selected = await showDatePicker(
      context: context,
      initialDate: isChat ? chatDate : orderDate,
      firstDate: DateTime(2024),
      lastDate: DateTime.now(),
    );

    if (!mounted || selected == null) return;

    setState(() {
      if (isChat) {
        chatDate = DateTime(selected.year, selected.month, selected.day,
            chatDate.hour, chatDate.minute, chatDate.second);
      } else {
        orderDate = DateTime(selected.year, selected.month, selected.day,
            orderDate.hour, orderDate.minute, orderDate.second);
      }
    });
  }

  Future<void> selectPaymentProof() async {
    try {
      final file = await _picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
      );

      if (!mounted || file == null) return;

      setState(() {
        paymentProof = file;
      });
    } catch (error) {
      showMessage('Tidak dapat memilih bukti bayar: $error');
    }
  }

  Future<void> selectProductPhotos(_ProductInput item) async {
    try {
      final files = await _picker.pickMultiImage(imageQuality: 85);

      if (!mounted || files.isEmpty) return;

      if (item.photos.length + files.length > 5) {
        showMessage('Maksimal 5 foto untuk setiap produk.');
        return;
      }

      setState(() {
        item.photos.addAll(files);
      });
    } catch (error) {
      showMessage('Tidak dapat memilih foto produk: $error');
    }
  }

  // Dialog dapat digulir sehingga rincian validasi Laravel tidak terpotong.
  Future<void> _showDetailedError(String title, String message) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: SelectableText(message),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Tutup'),
          ),
        ],
      ),
    );
  }

  String _submissionErrorDetail(DioException error) {
    final status = error.response?.statusCode;
    final body = error.response?.data;
    final lines = <String>[
      if (status != null) 'HTTP $status',
      if (error.requestOptions.path.isNotEmpty)
        'Endpoint: ${error.requestOptions.method} ${error.requestOptions.path}',
    ];
    if (body is Map) {
      final msg = body['message'] ?? body['error'];
      if (msg != null && msg.toString().trim().isNotEmpty) {
        lines.add('Pesan server: $msg');
      }
      final data = body['data'];
      if (data is Map && data['message'] != null) {
        lines.add('Detail server: ${data['message']}');
      }
      final errors = body['errors'] ?? (data is Map ? data['errors'] : null);
      if (errors is Map && errors.isNotEmpty) {
        lines.add('Kesalahan validasi:');
        for (final entry in errors.entries) {
          final value = entry.value;
          final detail = value is List ? value.join('; ') : value.toString();
          lines.add('• ${entry.key}: $detail');
        }
      }
    } else if (body is String && body.trim().isNotEmpty) {
      // Jangan menampilkan halaman HTML error (berpotensi mengandung data server).
      if (!body.trimLeft().startsWith('<')) {
        lines.add('Pesan server: $body');
      }
    }
    if (status == 401) lines.add('Sesi login tidak valid. Login ulang.');
    if (status == 403) lines.add('Akun tidak memiliki hak akses membuat pesanan.');
    if (status == 404) lines.add('Endpoint atau data pesanan tidak ditemukan.');
    if (status == 422) lines.add('Periksa field yang disebut dalam validasi.');
    if (status == 409) lines.add('Nomor pesanan bentrok; muat ulang nomor pesanan.');
    if (status != null && status >= 500) {
      lines.add('Terjadi kesalahan server. Periksa log Laravel berdasarkan waktu dan nomor pesanan.');
    }
    if (status == null) {
      lines.add('Jenis kegagalan koneksi: ${error.type.name}');
      lines.add('Tidak ada jawaban HTTP; pesanan mungkin sudah tersimpan. Periksa dahulu sebelum mengirim ulang.');
    }
    if (lines.length <= 2) lines.add('Tidak ada rincian tambahan dari server.');
    return lines.join('\n');
  }

  void showMessage(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 7),
      ),
    );
  }

  void addProduct() {
    setState(() {
      products.add(_ProductInput());
    });
  }

  void removeProduct(_ProductInput item) {
    if (products.length == 1) {
      showMessage('Minimal harus ada satu produk.');
      return;
    }

    setState(() {
      products.remove(item);
    });

    item.dispose();
  }

  bool get _hasUnsavedChanges {
    if (buyer.text.trim().isNotEmpty || phone.text.trim() != '62' ||
        address.text.trim().isNotEmpty || _provinceId != null ||
        _cityId != null || _districtId != null || _villageId != null ||
        payment != 'COD' || paymentProof != null ||
        nilaiCod != 0 || nilaiNonCod != 0 || nilaiDp != 0 ||
        products.length > 1) {
      return true;
    }
    final today = DateTime.now();
    if (!DateUtils.isSameDay(chatDate, today) ||
        !DateUtils.isSameDay(orderDate, today)) {
      return true;
    }
    return products.any((p) => p.categoryId != null || p.product != null ||
        p.variant != null || p.qty.text.trim() != '1' ||
        p.note.text.trim().isNotEmpty || p.photos.isNotEmpty);
  }

  Future<void> _requestCancel() async {
    if (_submitting || _checkingSubmission) {
      showMessage('Pengiriman sedang berlangsung. Jangan keluar dari formulir.');
      return;
    }
    if (_submissionUncertain) {
      showMessage('Status simpan belum pasti. Periksa nomor pesanan sebelum keluar.');
      return;
    }
    if (!_hasUnsavedChanges) {
      widget.onCancel();
      return;
    }
    final discard = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Keluar dari Tambah Pesanan?'),
        content: const Text('Data dan foto yang belum disimpan akan hilang.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Lanjut Isi')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Buang Isian & Keluar')),
        ],
      ),
    );
    if (discard == true && mounted) {
      _resetFormAfterSuccess();
      _loadOrderIdentity();
      widget.onCancel();
    }
  }

  // Saat POST timeout, cek berdasarkan nomor pesanan yang sama. Tidak
  // melakukan POST ulang sampai petugas memverifikasi statusnya.
  Future<void> _checkUncertainSubmission() async {
    final number = _uncertainOrderNumber;
    if (number == null || _checkingSubmission) return;
    setState(() => _checkingSubmission = true);
    try {
      final token = await _bearerToken();
      final response = await ApiClient.dio.get<dynamic>(
        '/pesanan/detail/${Uri.encodeComponent(number)}',
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      final data = response.data;
      if (response.statusCode == 200 && data is Map && data['success'] == true &&
          data['data'] is Map) {
        if (!mounted) return;
        final savedBuyer = buyer.text.trim();
        await _completeSuccessfulSave(number, savedBuyer);
      } else {
        showMessage('Belum dapat memastikan pesanan tersimpan. Cek Pesanan Saya sebelum mengirim ulang.');
      }
    } on DioException catch (e) {
      if (!mounted) return;
      showMessage(e.response?.statusCode == 404
          ? 'Pesanan belum ditemukan. Pastikan lewat Pesanan Saya sebelum mencoba ulang.'
          : 'Belum dapat memeriksa status pesanan. Periksa koneksi dan coba cek lagi.');
    } catch (_) {
      showMessage('Tidak dapat memeriksa pesanan. Coba lagi saat koneksi stabil.');
    } finally {
      if (mounted) setState(() => _checkingSubmission = false);
    }
  }

  Future<void> _allowManualRetry() async {
    final allow = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sudah memeriksa pesanan?'),
        content: Text('Pastikan pesanan $_uncertainOrderNumber tidak ada di Pesanan Saya atau database Laravel. '
            'Mengirim ulang tanpa memastikan dapat menimbulkan pesanan ganda.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Belum, Batal')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Sudah, Belum Tersimpan')),
        ],
      ),
    );
    if (allow == true && mounted) {
      setState(() {
        _submissionUncertain = false;
        _uncertainOrderNumber = null;
      });
      showMessage('Isian tetap tersimpan. Periksa lagi sebelum menekan Simpan.');
    }
  }

  void previewOrder() {
    // Tutup keyboard sebelum validasi / membuka preview.
    FocusManager.instance.primaryFocus?.unfocus();
    if (_submitting || _checkingSubmission) return;
    if (_submissionUncertain) {
      showMessage('Status pesanan sebelumnya belum pasti. Periksa dahulu sebelum mengirim ulang.');
      return;
    }
    if (_loadingIdentity || _orderNumber == null || _responsibleUserId == null) {
      showMessage('Nomor pesanan dan akun login belum siap. Muat ulang terlebih dahulu.');
      return;
    }
    if (!_formKey.currentState!.validate()) {
      showMessage('Lengkapi semua kolom yang wajib diisi, termasuk Provinsi sampai Desa.');
      return;
    }

    final chatDay = DateUtils.dateOnly(chatDate);
    final orderDay = DateUtils.dateOnly(orderDate);
    if (orderDay.isBefore(chatDay)) {
      showMessage('Tanggal order tidak boleh sebelum tanggal chat masuk.');
      return;
    }

    if (_provinceId == null || _cityId == null ||
        _districtId == null || _villageId == null) {
      showMessage('Pilih wilayah lengkap dari Provinsi sampai Desa terlebih dahulu.');
      return;
    }

    if (totalPrice <= 0) {
      showMessage('Nominal ${payment == 'DP' ? 'DP dan sisa COD' : payment} harus lebih dari Rp0.');
      return;
    }
    if (payment == 'COD' && amount(cod) <= 0) {
      showMessage('Nominal COD harus lebih dari Rp0.');
      return;
    }
    if (payment == 'NON COD' && amount(nonCod) <= 0) {
      showMessage('Nominal NON COD harus lebih dari Rp0.');
      return;
    }

    if (payment == 'DP' && (amount(dp) <= 0 || amount(cod) <= 0)) {
      showMessage('Isi nominal DP dan sisa COD.');
      return;
    }


    if (payment != 'COD' && paymentProof == null) {
      showMessage('Bukti transfer wajib dilampirkan untuk metode ${payment == 'DP' ? 'DP + Sisa COD' : 'NON COD'}.');
      return;
    }

    if (phone.text.trim().startsWith('62') &&
        !RegExp(r'^62[0-9]{8,13}$').hasMatch(phone.text.trim())) {
      showMessage('Nomor HP harus diawali 62 dan berisi 10–15 digit.');
      return;
    }

    if (totalJumlahProduk <= 0) {
      showMessage('Jumlah seluruh produk harus lebih dari nol.');
      return;
    }

    for (final item in products) {
      if (item.categoryId == null || item.product == null || item.sku == null) {
        showMessage('Pilih kategori, produk, dan variasi untuk setiap produk.');
        return;
      }

      if (amount(item.qty) < 1) {
        showMessage('Jumlah produk minimal 1.');
        return;
      }
      if (item.note.text.trim().isEmpty) {
        showMessage('Catatan Produk wajib diisi untuk setiap produk.');
        return;
      }
      if (item.photos.isEmpty || item.photos.length > 5) {
        showMessage('Setiap produk wajib memiliki 1 sampai 5 foto.');
        return;
      }
    }

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            10,
            20,
            MediaQuery.viewInsetsOf(context).bottom + 20,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Preview Pesanan (Belum Disimpan)',
                  style: TextStyle(
                    fontSize: 21,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.navy,
                  ),
                ),
                const SizedBox(height: 16),
                _info('Penanggung Jawab', responsibleName),
                _info('Pembeli', buyer.text),
                _info('Telepon', phone.text),
                _info('Provinsi', _regionName(_provinces, _provinceId)),
                _info('Kabupaten/Kota', _regionName(_cities, _cityId)),
                _info('Kecamatan', _regionName(_districts, _districtId)),
                _info('Desa', _regionName(_villages, _villageId)),
                _info('Alamat', address.text),
                _info('Pembayaran', payment),
                _info('Jumlah Produk', '${products.length} jenis'),
                _info('Total HPP', rupiah(totalHpp)),
                _info('Total Nilai Transaksi', rupiah(nilaiTransaksi)),
                _info('Biaya Admin 3,33% COD', rupiah(totalAdmin)),
                _info('COD', rupiah(nilaiCod)),
                _info('NON COD', rupiah(nilaiNonCod)),
                _info('DP', rupiah(nilaiDp)),
                _info('Total Harga API', rupiah(totalPrice)),
                const Divider(height: 28),
                ...products.map(
                  (item) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Text(
                      '${item.product} — ${item.variant ?? '-'} (${item.qty.text} pcs) '
                      '• SKU ${item.sku ?? '-'} • HPP ${rupiah((item.hpp ?? 0).round())} '
                      '• ${item.photos.length} foto',
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Periksa data sebelum menyimpan ke server.',
                  style: TextStyle(color: Colors.deepOrange, fontSize: 12),
                ),
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      FilledButton.icon(
                        onPressed: _submitting ? null : () async {
                          FocusManager.instance.primaryFocus?.unfocus();
                          Navigator.pop(context);
                          await _submitOrder();
                        },
                        icon: const Icon(Icons.cloud_upload_outlined),
                        label: const Text('Konfirmasi & Simpan Pesanan'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Kembali ke Form'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _dateTimeApi(DateTime date) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${date.year}-${two(date.month)}-${two(date.day)} '
        '${two(date.hour)}:${two(date.minute)}:${two(date.second)}';
  }

  // CS Shell memakai IndexedStack. Halaman ini tidak otomatis di-dispose
  // ketika pindah tab, sehingga semua input harus dibersihkan secara eksplisit
  // setelah server benar-benar mengembalikan HTTP 201.
  void _resetFormAfterSuccess() {
    ++_cityRequest;
    ++_districtRequest;
    ++_villageRequest;
    ++_addressRequest;
    for (final item in products) {
      item.dispose();
    }
    buyer.clear();
    phone.text = '62';
    province.clear();
    city.clear();
    district.clear();
    village.clear();
    address.clear();
    cod.text = '0';
    nonCod.text = '0';
    dp.text = '0';
    setState(() {
      _formKey = GlobalKey<FormState>();
      products
        ..clear()
        ..add(_ProductInput());
      _provinceId = null;
      _cityId = null;
      _districtId = null;
      _villageId = null;
      _postalCode = null;
      _cities = [];
      _districts = [];
      _villages = [];
      _cityError = null;
      _districtError = null;
      _villageError = null;
      _loadingCities = false;
      _loadingDistricts = false;
      _loadingVillages = false;
      payment = 'COD';
      paymentProof = null;
      chatDate = DateTime.now();
      orderDate = DateTime.now();
      _orderNumber = null;
      _submissionUncertain = false;
      _uncertainOrderNumber = null;
    });
  }

  Future<void> _showSaveSuccess(String number, String buyerName) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.check_circle, color: Color(0xFF0B8B65)),
            SizedBox(width: 10),
            Expanded(child: Text('Pesanan Berhasil Disimpan')),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Pesanan $buyerName telah berhasil ditambahkan ke Laravel.'),
            const SizedBox(height: 8),
            Text('No. Pesanan: $number',
                style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            const Text('Beranda dan Pesanan Saya sedang diperbarui otomatis.'),
          ],
        ),
        actions: [
          FilledButton.icon(
            onPressed: () => Navigator.of(dialogContext).pop(),
            icon: const Icon(Icons.receipt_long_outlined),
            label: const Text('Lihat Pesanan Saya'),
          ),
        ],
      ),
    );
  }

  Future<void> _completeSuccessfulSave(String number, String savedBuyer) async {
    if (!mounted) return;
    _resetFormAfterSuccess();
    CsOrderUpdates.orderCreated();
    await _showSaveSuccess(number, savedBuyer);
    if (!mounted) return;
    _loadOrderIdentity();
    widget.onCancel();
  }

  Future<void> _submitOrder() async {
    FocusManager.instance.primaryFocus?.unfocus();
    if (_submitting || _submissionUncertain || _orderNumber == null || _responsibleUserId == null) return;
    setState(() => _submitting = true);
    try {
      final token = await _bearerToken();
      final values = <String, dynamic>{
        'no_pesanan': _orderNumber!,
        'platform': 'meta',
        'tanggal': _dateTimeApi(orderDate),
        'tanggal_order': _dateTimeApi(orderDate),
        'chat_masuk_at': _dateTimeApi(chatDate),
        'user_id': _responsibleUserId!,
        'nama_pembeli': buyer.text.trim(),
        'total_hpp': totalHpp,
        'total_harga': totalPrice,
        'total_admin': totalAdmin,
        'resi_print_count': 0,
        'provinsi': _provinceId!,
        'kabupaten_kota': _cityId!,
        'kecamatan': _districtId!,
        'desa': _villageId!,
        'alamat_lengkap': address.text.trim(),
        'phone': phone.text.trim(),
        'jenis_transaksi': payment == 'NON COD' ? 'non-cod' : payment.toLowerCase(),
        // Sesuai metode: COD saja, NON COD saja, atau DP + sisa COD.
        'cod': nilaiCod,
        'non_cod': nilaiNonCod,
        'dp': nilaiDp,
      };
      if (paymentProof != null) {
        final file = File(paymentProof!.path);
        if (await file.length() > 5 * 1024 * 1024) {
          throw const FormatException('Bukti pembayaran melebihi 5 MB.');
        }
        values['bukti_bayar'] = await MultipartFile.fromFile(
          paymentProof!.path, filename: paymentProof!.name,
        );
      }
      for (var i = 0; i < products.length; i++) {
        final item = products[i];
        final prefix = 'pesanan_perproduk[$i]';
        values['$prefix[nama_produk]'] = item.product!;
        values['$prefix[variasi]'] = item.variant!;
        values['$prefix[sku]'] = item.sku!;
        values['$prefix[jumlah]'] = amount(item.qty);
        values['$prefix[hpp]'] = item.hpp ?? 0;
        values['$prefix[harga]'] = hargaJualApi();
        // Backend masih mensyaratkan custom: isi placeholder tanpa kolom UI.
        values['$prefix[custom]'] = '-';
        values['$prefix[catatan]'] = item.note.text.trim();
        values['$prefix[status_pesanan]'] = 0;
        for (var j = 0; j < item.photos.length; j++) {
          final photo = item.photos[j];
          final ext = photo.name.split('.').last.toLowerCase();
          if (!['jpg', 'jpeg', 'png'].contains(ext)) {
            throw FormatException('Foto produk ${i + 1} nomor ${j + 1} harus JPG atau PNG.');
          }
          if (await File(photo.path).length() > 5 * 1024 * 1024) {
            throw FormatException('Foto produk ${i + 1} nomor ${j + 1} melebihi 5 MB.');
          }
          values['$prefix[foto_produk][$j]'] = await MultipartFile.fromFile(
            photo.path, filename: photo.name,
          );
        }
      }
      final result = await ApiClient.dio.post<dynamic>(
        '/pesanan/store',
        data: FormData.fromMap(values),
        options: Options(
          headers: {'Authorization': 'Bearer $token', 'Accept': 'application/json'},
          contentType: 'multipart/form-data',
          receiveTimeout: const Duration(seconds: 90),
          sendTimeout: const Duration(seconds: 90),
        ),
      );
      final savedBody = result.data;
      final validStatus = result.statusCode == 201 || result.statusCode == 200;
      if (!validStatus || savedBody is! Map || savedBody['success'] != true) {
        throw FormatException('Respons simpan pesanan tidak sesuai. '
            'HTTP ${result.statusCode}; pesan: '
            '${savedBody is Map ? (savedBody['message'] ?? savedBody['error'] ?? savedBody['data']) : savedBody}');
      }
      if (!mounted) return;
      final savedNumber = (result.data['data'] is Map
              ? (result.data['data'] as Map)['no_pesanan']?.toString()
              : null) ?? _orderNumber!;
      final savedBuyer = buyer.text.trim();
      await _completeSuccessfulSave(savedNumber, savedBuyer);
    } on DioException catch (error) {
      if (!mounted) return;
      final status = error.response?.statusCode;
      final detail = _submissionErrorDetail(error);
      if (status == 409) {
        // Form tidak dihapus, hanya minta nomor pesanan baru.
        _loadOrderIdentity();
      } else if (status == null) {
        setState(() {
          _submissionUncertain = true;
          _uncertainOrderNumber = _orderNumber;
        });
      }
      await _showDetailedError('Gagal Menyimpan Pesanan', detail);
    } catch (error) {
      if (!mounted) return;
      await _showDetailedError('Gagal Menyimpan Pesanan',
          'Gagal memproses permintaan: $error');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Widget _info(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(label, style: const TextStyle(color: Colors.black54)),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Widget section(String title, List<Widget> children) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE5EBF2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: AppTheme.navy,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),
          ...children,
        ],
      ),
    );
  }

  Widget field(
    String label,
    TextEditingController controller, {
    bool required = true,
    int lines = 1,
    TextInputType? keyboard,
    List<TextInputFormatter>? formatters,
    ValueChanged<String>? onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 13),
      child: TextFormField(
        controller: controller,
        onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
        maxLines: lines,
        keyboardType: keyboard,
        inputFormatters: formatters,
        onChanged: onChanged,
        decoration: InputDecoration(
          labelText: label,
          alignLabelWithHint: lines > 1,
        ),
        validator: (value) {
          final text = value?.trim() ?? '';

          if (required && text.isEmpty) {
            return '$label wajib diisi';
          }

          if (controller == phone &&
              !RegExp(r'^62[0-9]{8,13}$').hasMatch(text)) {
            return 'Nomor HP harus diawali 62';
          }

          return null;
        },
      ),
    );
  }

  Widget moneyField(String title, TextEditingController controller) {
    return field(
      title,
      controller,
      keyboard: TextInputType.number,
      formatters: [FilteringTextInputFormatter.digitsOnly],
      onChanged: (_) => setState(() {}),
    );
  }

  Widget dateField(String label, DateTime date, bool isChat) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 13),
      child: OutlinedButton.icon(
        onPressed: () => selectDate(isChat: isChat),
        icon: const Icon(Icons.calendar_today_outlined),
        label: Text('$label: ${dateLabel(date)}'),
        style: OutlinedButton.styleFrom(
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.all(14),
        ),
      ),
    );
  }

  Widget productCard(_ProductInput item, int index) {
    final names = item.categoryId == null
        ? <_ProductOption>[]
        : _productsByCategory[item.categoryId] ?? <_ProductOption>[];
    _ProductOption? chosen;
    for (final p in names) {
      if (p.name == item.product) { chosen = p; break; }
    }
    final variations = chosen?.variants ?? <_VariantOption>[];

    return Container(
      key: ObjectKey(item),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: const Color(0xFFF7FAFE),
        border: Border.all(color: const Color(0xFFDCE7F3)),
        borderRadius: BorderRadius.circular(13),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Produk ${index + 1}',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    color: AppTheme.navy,
                  ),
                ),
              ),
              if (products.length > 1)
                IconButton(
                  tooltip: 'Hapus produk',
                  onPressed: () => removeProduct(item),
                  icon: const Icon(Icons.delete_outline, color: Colors.red),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (_loadingCategories) const LinearProgressIndicator(),
          if (_categoriesError != null) ...[
            Text(_categoriesError!, style: const TextStyle(color: Colors.red)),
            TextButton(onPressed: _loadCategories, child: const Text('Ulangi Kategori')),
          ],
          _searchSelector(
            label: 'Kategori Produk',
            selectedLabel: item.categoryId == null ? null :
                _categories.where((c) => c.id == item.categoryId).map((c) => c.name).firstOrNull,
            onTap: _loadingCategories || _categories.isEmpty ? null : () async {
              final chosen = await _searchOption<_CategoryOption>(
                title: 'Cari Kategori Produk',
                options: _categories,
                labelOf: (c) => c.name,
              );
              if (chosen != null && mounted) _selectCategory(item, chosen.id);
            },
          ),
          const SizedBox(height: 13),
          if (item.loadingProducts) const LinearProgressIndicator(),
          if (item.productsError != null) ...[
            Text(item.productsError!, style: const TextStyle(color: Colors.red)),
            TextButton(onPressed: () {
              final id = item.categoryId;
              if (id != null) _selectCategory(item, id, forceReload: true);
            }, child: const Text('Ulangi Produk')),
          ],
          _searchSelector(
            label: 'Nama Produk',
            selectedLabel: item.product,
            onTap: item.loadingProducts || names.isEmpty ? null : () async {
              final chosen = await _searchOption<_ProductOption>(
                title: 'Cari Nama Produk',
                options: names,
                labelOf: (p) => p.name,
              );
              if (chosen != null && mounted) {
                setState(() {
                  item.product = chosen.name;
                  item.variant = null;
                  item.sku = null;
                  item.hpp = null;
                });
              }
            },
          ),
          const SizedBox(height: 13),
          _searchSelector(
            label: 'Variasi Produk',
            selectedLabel: item.variant,
            onTap: variations.isEmpty ? null : () async {
              final chosen = await _searchOption<_VariantOption>(
                title: 'Cari Variasi Produk',
                options: variations,
                labelOf: (v) => v.name,
                subtitleOf: (v) => '${v.sku} • ${rupiah(v.hpp.round())}',
              );
              if (chosen != null && mounted) {
                setState(() {
                  item.sku = chosen.sku;
                  item.variant = chosen.name;
                  item.hpp = chosen.hpp;
                });
              }
            },
          ),
          const SizedBox(height: 12),
          InputDecorator(
            decoration: const InputDecoration(labelText: 'SKU (otomatis)'),
            child: Text(item.sku ?? '-', style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          const SizedBox(height: 12),
          InputDecorator(
            decoration: const InputDecoration(labelText: 'HPP satuan (otomatis)'),
            child: Text(item.hpp == null ? '-' : rupiah(item.hpp!.round()), style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          const SizedBox(height: 13),
          field(
            'Jumlah',
            item.qty,
            keyboard: TextInputType.number,
            formatters: [FilteringTextInputFormatter.digitsOnly],
            onChanged: (_) => setState(() {}),
          ),
          _info('Subtotal HPP', rupiah(((item.hpp ?? 0) * amount(item.qty)).round())),
          field('Catatan Produk', item.note, lines: 2),
          OutlinedButton.icon(
            onPressed: () => selectProductPhotos(item),
            icon: const Icon(Icons.add_photo_alternate_outlined),
            label: Text('Pilih Foto Produk (${item.photos.length}/5)'),
          ),
          if (item.photos.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: item.photos.map((photo) {
                return Stack(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(9),
                      child: Image.file(
                        File(photo.path),
                        width: 75,
                        height: 75,
                        fit: BoxFit.cover,
                      ),
                    ),
                    Positioned(
                      top: 0,
                      right: 0,
                      child: InkWell(
                        onTap: () {
                          setState(() {
                            item.photos.remove(photo);
                          });
                        },
                        child: const CircleAvatar(
                          radius: 11,
                          backgroundColor: Colors.red,
                          child: Icon(
                            Icons.close,
                            color: Colors.white,
                            size: 14,
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              }).toList(),
            ),
          ],
          const SizedBox(height: 8),
          const Text(
            'SKU dan HPP mengikuti variasi master produk Laravel.',
            style: TextStyle(fontSize: 11, color: Colors.black54),
          ),
        ],
      ),
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
              ),
              borderRadius: BorderRadius.vertical(bottom: Radius.circular(24)),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Tambah Pesanan',
                  style: TextStyle(
                    fontSize: 23,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                SizedBox(height: 5),
                Text(
                  'Form pemesanan Meta • Integrasi bertahap',
                  style: TextStyle(color: Color(0xFFD2E5F7), fontSize: 12),
                ),
              ],
            ),
          ),
          Expanded(
            child: AbsorbPointer(
              absorbing: _submitting || _checkingSubmission,
              child: Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.all(15),
                children: [
                  section('01 · Identitas Pesanan', [
                    InputDecorator(
                      decoration: const InputDecoration(
                        labelText: 'Penanggung Jawab Pesanan',
                        prefixIcon: Icon(Icons.person_outline),
                      ),
                      child: Text(
                        _loadingIdentity
                            ? 'Memuat...'
                            : responsibleName,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          color: AppTheme.navy,
                        ),
                      ),
                    ),
                    if (_identityError != null) ...[
                      const SizedBox(height: 10),
                      Text(_identityError!, style: const TextStyle(color: Colors.red)),
                      TextButton.icon(
                        onPressed: _loadOrderIdentity,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Coba Lagi'),
                      ),
                    ],
                    const SizedBox(height: 15),
                    dateField('Tanggal Chat Masuk', chatDate, true),
                    dateField('Tanggal Order', orderDate, false),
                    field('Nama Pembeli', buyer),
                    field(
                      'No. HP (awalan 62)',
                      phone,
                      keyboard: TextInputType.phone,
                      formatters: [FilteringTextInputFormatter.digitsOnly],
                    ),
                  ]),

                  section('02 · Alamat Pengiriman', [
                    const Text(
                      'Cari dan pilih nama wilayah secara berurutan.',
                      style: TextStyle(fontSize: 12, color: Colors.black54),
                    ),
                    const SizedBox(height: 12),
                    _regionDropdown(
                      label: 'Provinsi',
                      selected: _provinceId,
                      options: _provinces,
                      loading: _loadingProvinces,
                      error: _provinceError,
                      retry: _loadProvinces,
                      onChanged: _selectProvince,
                    ),
                    _regionDropdown(
                      label: 'Kabupaten / Kota',
                      selected: _cityId,
                      options: _cities,
                      loading: _loadingCities,
                      enabled: _provinceId != null,
                      error: _cityError,
                      retry: _provinceId == null ? null : () => _loadCities(_provinceId!),
                      onChanged: _selectCity,
                    ),
                    _regionDropdown(
                      label: 'Kecamatan',
                      selected: _districtId,
                      options: _districts,
                      loading: _loadingDistricts,
                      enabled: _cityId != null,
                      error: _districtError,
                      retry: _cityId == null ? null : () => _loadDistricts(_cityId!),
                      onChanged: _selectDistrict,
                    ),
                    _regionDropdown(
                      label: 'Desa / Kelurahan',
                      selected: _villageId,
                      options: _villages,
                      loading: _loadingVillages,
                      enabled: _districtId != null,
                      error: _villageError,
                      retry: _districtId == null ? null : () => _loadVillages(_districtId!),
                      onChanged: _selectVillage,
                    ),
                    if (_postalCode != null && _postalCode!.isNotEmpty) ...[
                      Text('Kode Pos: $_postalCode',
                          style: const TextStyle(fontSize: 12, color: Colors.black54)),
                      const SizedBox(height: 12),
                    ],
                    field('Alamat Lengkap', address, lines: 3),
                  ]),

                  section('03 · Pembayaran', [
                    DropdownButtonFormField<String>(
                      initialValue: payment,
                      decoration: const InputDecoration(
                        labelText: 'Metode Pembayaran',
                      ),
                      items: const [
                        DropdownMenuItem(value: 'COD', child: Text('COD')),
                        DropdownMenuItem(
                          value: 'NON COD',
                          child: Text('NON COD'),
                        ),
                        DropdownMenuItem(
                          value: 'DP',
                          child: Text('DP + Sisa COD'),
                        ),
                      ],
                      onChanged: (value) {
                        if (value != null) _changePayment(value);
                      },
                    ),
                    const SizedBox(height: 15),
                    if (payment == 'COD')
                      moneyField('Nominal COD (Rp)', cod),
                    if (payment == 'NON COD')
                      moneyField('Nominal NON COD (Rp)', nonCod),
                    if (payment == 'DP') ...[
                      moneyField('Nominal DP (Rp)', dp),
                      moneyField('Sisa COD (Rp)', cod),
                    ],
                    const Padding(
                      padding: EdgeInsets.only(bottom: 12),
                      child: Text(
                        'Nominal metode lain otomatis Rp0. Total harga adalah jumlah nominal pembayaran yang aktif.',
                        style: TextStyle(fontSize: 12, color: Colors.black54),
                      ),
                    ),
                    if (payment == 'NON COD' || payment == 'DP') ...[
                      OutlinedButton.icon(
                        onPressed: selectPaymentProof,
                        icon: const Icon(Icons.upload_file),
                        label: Text(
                          paymentProof == null
                              ? 'Pilih Bukti Transfer'
                              : 'Ganti Bukti Transfer',
                        ),
                      ),
                      if (paymentProof != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          paymentProof!.name,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ],
                    ],
                  ]),

                  section('04 · Produk Pesanan', [
                    const Text(
                      'Kategori, produk, variasi, SKU, dan HPP diambil dari Laravel.',
                      style: TextStyle(fontSize: 12, color: Colors.black54),
                    ),
                    const SizedBox(height: 13),
                    for (int i = 0; i < products.length; i++)
                      productCard(products[i], i),
                    OutlinedButton.icon(
                      onPressed: addProduct,
                      icon: const Icon(Icons.add),
                      label: const Text('Tambah Produk Lagi'),
                    ),
                  ]),

                  section('05 · Rincian Pesanan', [
                    _info('Metode Bayar', payment),
                    _info('COD', rupiah(nilaiCod)),
                    _info('NON COD', rupiah(nilaiNonCod)),
                    _info('DP', rupiah(nilaiDp)),
                    const Divider(),
                    _info('Total Harga / Nilai Transaksi', rupiah(totalPrice)),
                    _info('Total HPP Produk', rupiah(totalHpp)),
                    _info('Admin (3,33% dari COD)', rupiah(totalAdmin)),
                    _info('Jumlah Produk', '${products.length} jenis'),
                    const SizedBox(height: 8),
                    const Text(
                      'Harga satuan dihitung otomatis: nilai transaksi / total jumlah pcs. '
                      'Total HPP = jumlah × HPP satuan. Admin dibulatkan ke rupiah terdekat.',
                      style: TextStyle(fontSize: 11, color: Colors.black54),
                    ),
                    const SizedBox(height: 16),
                  ]),

                  if (_submissionUncertain) section('Status Pesanan Belum Pasti', [
                    Text('Nomor pesanan: ${_uncertainOrderNumber ?? '-'}'),
                    const SizedBox(height: 8),
                    const Text('Koneksi terputus saat simpan. Jangan kirim ulang sampai memastikan pesanan belum tersimpan.'),
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      onPressed: _checkingSubmission ? null : _checkUncertainSubmission,
                      icon: const Icon(Icons.fact_check_outlined),
                      label: Text(_checkingSubmission ? 'Memeriksa...' : 'Periksa Status di Laravel'),
                    ),
                    TextButton(
                      onPressed: _checkingSubmission ? null : _allowManualRetry,
                      child: const Text('Saya Sudah Memastikan Belum Tersimpan'),
                    ),
                  ]),
                  FilledButton.icon(
                    onPressed: _submitting || _submissionUncertain || _loadingIdentity || _orderNumber == null ? null : previewOrder,
                    icon: const Icon(Icons.visibility_outlined),
                    label: Text(_submitting ? 'Menyimpan...' : 'Preview & Simpan Pesanan'),
                  ),
                  if (_submitting) const Padding(
                    padding: EdgeInsets.symmetric(vertical: 10),
                    child: LinearProgressIndicator(),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton(
                    onPressed: _submitting ? null : _requestCancel,
                    child: const Text('Kembali ke Pesanan'),
                  ),
                  const SizedBox(height: 20),
                ],
              ),
            ),
          ),
          ),
        ],
      ),
    );
  }
}